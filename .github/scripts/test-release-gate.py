#!/usr/bin/env python3
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("verify-release-source.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.run = dict(id=123, run_attempt=2, head_sha=self.sha, head_branch="main",
                        event="push", status="completed", conclusion="success",
                        path=".github/workflows/helm-ci.yml",
                        repository={"full_name": "owner/repo"}, head_repository={"full_name": "owner/repo"})

    def test_matching_main_ci(self):
        gate.verify(self.run, "owner/repo", self.sha, 123, 2)

    def test_all_provenance_fields_fail_closed(self):
        changes = dict(id=124, run_attempt=1, head_sha="b" * 40, head_branch="feature",
                       event="pull_request", status="in_progress", conclusion="failure",
                       path=".github/workflows/other.yml",
                       repository={"full_name": "fork/repo"}, head_repository={"full_name": "fork/repo"})
        for key, value in changes.items():
            with self.subTest(key=key):
                altered = copy.deepcopy(self.run)
                altered[key] = value
                with self.assertRaises(ValueError):
                    gate.verify(altered, "owner/repo", self.sha, 123, 2)
                del altered[key]
                with self.assertRaises(ValueError):
                    gate.verify(altered, "owner/repo", self.sha, 123, 2)

    def test_release_dependency_and_package_binding(self):
        workflow = (Path(__file__).parents[1] / "workflows/release.yml").read_text()
        release = workflow.split("\n  release:\n", 1)[1]
        self.assertIn("needs: real-cluster-acceptance", release)
        self.assertIn("needs.real-cluster-acceptance.result == 'success'", release)
        self.assertIn("artifact-ids: ${{ needs.real-cluster-acceptance.outputs.artifact_id }}", release)
        self.assertLess(release.index('test "$package_sha" = "$ACCEPTED_SHA256"'),
                        release.index("Prepare verified GitHub release draft"))
        self.assertIn("environment: paperless-release-acceptance", workflow)
        self.assertNotIn("continue-on-error", workflow)

    def test_real_cluster_wrapper_fails_closed_and_hides_private_logs(self):
        wrapper = Path(__file__).with_name("run-real-cluster-acceptance.sh").resolve()
        for failure in ("", "dns", "tls", "marker", "storage", "crd", "v2", "v3"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "bin").mkdir()
                (root / "scripts").mkdir()
                mocks = {
                    "kubectl": '''#!/bin/bash
case "$*" in
  *"config view"*)
    if [[ "$FAILURE" == tls ]]; then
      printf '%s' '{"clusters":[{"cluster":{"server":"https://test.invalid","insecure-skip-tls-verify":true}}]}'
    else
      printf '%s' '{"clusters":[{"cluster":{"server":"https://test.invalid"}}]}'
    fi ;;
  *"get --raw"*) [[ "$FAILURE" != dns ]] ;;
  *"get configmap"*) [[ "$FAILURE" != marker ]] && printf '%s' paperless-isolated-release-tests ;;
  *"get storageclass"*) [[ "$FAILURE" != storage ]] && printf '%s' '{"reclaimPolicy":"Delete"}' ;;
  *"get crd"*) [[ "$FAILURE" != crd ]] ;;
  *) exit 99 ;;
esac
''',
                    "curl": '''#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == https://* ]]; then url=$arg; fi
done
printf '%s' "$url" > "${@: -1}"
''',
                    "sha256sum": '''#!/bin/bash
if [[ "$1" == *candidate.tgz ]]; then
  printf '%s  candidate\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
elif grep -q 0.3.23 "$1"; then
  printf '%s  baseline\n' 6202d81c112d3e810d9abb37e16d5aa141a7b6a4e85911d4ff0c257f275beb22
else
  printf '%s  baseline\n' fcd72197aeb88735f64ba571d65ff882999ada4507238ce86bc7ee5e952d72df
fi
''',
                }
                for name, content in mocks.items():
                    path = root / "bin" / name
                    path.write_text(content)
                    path.chmod(0o700)
                runner = root / "scripts/paperless-e2e.sh"
                runner.write_text('''#!/bin/bash
set -e
test "$CLEANUP_NAMESPACE" = true
test "$MONITORING_E2E" = true
test "$REQUIRE_NETWORK_POLICY_ENFORCEMENT" = true
[[ "$NAMESPACE" == paperless-ci-* ]]
printf '%s\n' "$BASE_CHART_VERSION" >> "$TEST_CALLS"
echo PRIVATE_CLUSTER_DIAGNOSTIC
if [[ "$FAILURE:$BASE_CHART_VERSION" == v2:0.3.23 ]]; then exit 22; fi
if [[ "$FAILURE:$BASE_CHART_VERSION" == v3:0.4.0-experimental.1 ]]; then exit 23; fi
''')
                runner.chmod(0o700)
                candidate = root / "candidate.tgz"
                candidate.write_text("synthetic")
                output = root / "output"
                calls = root / "calls"
                env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                           KUBECONFIG="test-only", KUBE_CONTEXT="test", EXPECTED_KUBE_SERVER="https://test.invalid",
                           E2E_STORAGE_CLASS="test", ACCEPTANCE_ENABLED="true", SOURCE_SHA=self.sha,
                           GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2", GITHUB_OUTPUT=str(output),
                           TEST_CALLS=str(calls), FAILURE=failure, KUBE_INSECURE_SKIP_TLS_VERIFY="false")
                result = subprocess.run(["bash", str(wrapper), str(candidate)], cwd=root, env=env,
                                        text=True, capture_output=True, timeout=15)
                self.assertNotIn("PRIVATE_CLUSTER_DIAGNOSTIC", result.stdout + result.stderr)
                if failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                    if failure == "v2":
                        self.assertEqual(calls.read_text().splitlines(), ["0.3.23"])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("sha256=" + "a" * 64, output.read_text())
                    self.assertEqual(calls.read_text().splitlines(), ["0.3.23", "0.4.0-experimental.1"])


if __name__ == "__main__":
    unittest.main()
