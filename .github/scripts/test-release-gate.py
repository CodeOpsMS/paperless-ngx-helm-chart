#!/usr/bin/env python3
import copy
import importlib.util
import json
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
        self.assertIn("needs: github-cluster-acceptance", release)
        self.assertIn("needs.github-cluster-acceptance.result == 'success'", release)
        self.assertIn("artifact-ids: ${{ needs.github-cluster-acceptance.outputs.artifact_id }}", release)
        self.assertLess(release.index('test "$package_sha" = "$ACCEPTED_SHA256"'),
                        release.index("Prepare verified GitHub release draft"))
        self.assertLess(release.index('test "$SOURCE_SHA" = "$ACCEPTED_SOURCE_SHA"'),
                        release.index("Prepare verified GitHub release draft"))
        acceptance = workflow.split("\n  github-cluster-acceptance:\n", 1)[1].split("\n  release:\n", 1)[0]
        self.assertIn("needs: verify-ci", acceptance)
        self.assertIn("uses: ./.github/workflows/cluster-acceptance.yml", acceptance)
        self.assertIn('--jobs "$RUNNER_TEMP/ci-jobs.json"', workflow)
        for forbidden in ("environment:", "ACCEPTANCE_KUBE", "WIREGUARD", "self-hosted"):
            self.assertNotIn(forbidden, workflow)
        self.assertNotIn("continue-on-error", workflow)

    def test_shared_cluster_acceptance_is_exercised_in_ci_without_secrets(self):
        workflows = Path(__file__).parents[1] / "workflows"
        ci = (workflows / "helm-ci.yml").read_text()
        shared = (workflows / "cluster-acceptance.yml").read_text()
        job = ci.split("\n  release-acceptance:\n", 1)[1].split("\n  full-fresh-matrix:\n", 1)[0]
        self.assertIn("uses: ./.github/workflows/cluster-acceptance.yml", job)
        self.assertIn("needs: candidate", job)
        self.assertIn("github.event_name != 'pull_request'", job)
        self.assertIn("workflow_call:", shared)
        self.assertIn("runs-on: ubuntu-latest", shared)
        self.assertIn("config: .github/kind-monitoring.yaml", shared)
        self.assertIn("run-kind-acceptance.sh", shared)
        self.assertNotIn("helm package", shared)
        for forbidden in ("continue-on-error", "environment:", "secrets: inherit", "ACCEPTANCE_KUBE", "WIREGUARD"):
            self.assertNotIn(forbidden, shared)

    def job_pages(self):
        jobs = []
        for prefix, count, step in gate.REQUIRED_JOBS:
            for index in range(count):
                jobs.append(dict(name=f"{prefix}{index}", run_id=123, head_sha=self.sha,
                                 status="completed", conclusion="success",
                                 steps=[dict(name=step, status="completed", conclusion="success")]))
        return [{"jobs": jobs[:5]}, {"jobs": jobs[5:]}]

    def test_complete_paginated_ci_jobs(self):
        gate.verify_jobs(self.job_pages(), self.sha, 123)

    def test_missing_duplicate_skipped_failed_or_mixed_jobs_block_release(self):
        for family in range(len(gate.REQUIRED_JOBS)):
            for failure in ("missing", "duplicate", "skipped", "cancelled", "failure", "source", "run", "running", "step"):
                with self.subTest(family=family, failure=failure):
                    jobs = [job for page in self.job_pages() for job in page["jobs"]]
                    target = next(job for job in jobs if job["name"].startswith(gate.REQUIRED_JOBS[family][0]))
                    if failure == "missing":
                        jobs.remove(target)
                    elif failure == "duplicate":
                        jobs.append(copy.deepcopy(target))
                    elif failure == "source":
                        target["head_sha"] = "b" * 40
                    elif failure == "run":
                        target["run_id"] = 124
                    elif failure == "running":
                        target["status"] = "in_progress"
                    elif failure == "step":
                        target["steps"][0]["conclusion"] = "skipped"
                    else:
                        target["conclusion"] = failure
                    with self.assertRaises(ValueError):
                        gate.verify_jobs([{"jobs": jobs}], self.sha, 123)

    def test_required_steps_must_exist_and_succeed_despite_green_job(self):
        for state in ([], [dict(name="unrelated")],
                      [dict(name="Run chart unit tests", status="completed", conclusion="failure")],
                      [dict(name="Run chart unit tests", status="in_progress", conclusion="success")]):
            with self.subTest(state=state):
                pages = self.job_pages()
                pages[0]["jobs"][0]["steps"] = state
                with self.assertRaises(ValueError):
                    gate.verify_jobs(pages, self.sha, 123)

    def test_cli_requires_job_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "run.json").write_text(json.dumps(self.run))
            (root / "jobs.json").write_text(json.dumps(self.job_pages()))
            cmd = ["python3", str(Path(__file__).with_name("verify-release-source.py")),
                   str(root / "run.json"), "owner/repo", self.sha, "123", "2"]
            self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
            self.assertEqual(subprocess.run(cmd + ["--jobs", str(root / "jobs.json")],
                                            capture_output=True).returncode, 0)

    def test_kind_wrapper_fails_closed(self):
        wrapper = Path(__file__).with_name("run-kind-acceptance.sh").resolve()
        for failure in ("", "context", "ci", "job", "download", "baseline", "v2", "v3", "cleanup", "tamper"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "bin").mkdir()
                (root / "scripts").mkdir()
                mocks = {
                    "kubectl": '''#!/bin/bash
[[ "$*" == "config current-context" ]] || exit 99
if [[ "$FAILURE" == context ]]; then echo unrelated-cluster; else echo kind-chart-testing; fi
''',
                    "curl": '''#!/bin/bash
[[ "$FAILURE" != download ]] || exit 22
printf '%s' "$*" > "${@: -1}"
''',
                    "sha256sum": '''#!/bin/bash
if [[ "$1" == *candidate.tgz ]]; then
  if grep -q tampered "$1"; then printf '%064d\n' 1; else printf '%064d\n' 0; fi
elif [[ "$FAILURE" == baseline ]]; then
  printf '%064d\n' 2
elif grep -q 0.3.23 "$1"; then
  echo 6202d81c112d3e810d9abb37e16d5aa141a7b6a4e85911d4ff0c257f275beb22
else
  echo fcd72197aeb88735f64ba571d65ff882999ada4507238ce86bc7ee5e952d72df
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
test "$KUBE_CONTEXT" = kind-chart-testing
test "$KUBE_INSECURE_SKIP_TLS_VERIFY" = false
test "$CLEANUP_NAMESPACE" = true
test "$MONITORING_E2E" = true
test "$REQUIRE_NETWORK_POLICY_ENFORCEMENT" = true
[[ "$NAMESPACE" == paperless-ci-123-2-* ]]
printf '%s\n' "$BASE_CHART_VERSION" >> "$TEST_CALLS"
if [[ "$FAILURE:$BASE_CHART_VERSION" == v2:0.3.23 ]]; then exit 22; fi
if [[ "$FAILURE:$BASE_CHART_VERSION" == v3:0.4.0-experimental.1 ]]; then exit 23; fi
if [[ "$FAILURE" == cleanup ]]; then exit 24; fi
if [[ "$FAILURE" == tamper ]]; then echo tampered > "$2"; fi
''')
                runner.chmod(0o700)
                candidate = root / "candidate.tgz"
                candidate.write_text("synthetic")
                output = root / "output"
                calls = root / "calls"
                env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                           CI="false" if failure == "ci" else "true",
                           GITHUB_JOB="wrong" if failure == "job" else "kind-acceptance",
                           SOURCE_SHA=self.sha, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2",
                           GITHUB_OUTPUT=str(output), TEST_CALLS=str(calls), FAILURE=failure)
                result = subprocess.run(["bash", str(wrapper), str(candidate)], cwd=root, env=env,
                                        text=True, capture_output=True, timeout=15)
                if failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                    if failure in ("ci", "job", "context", "download", "baseline"):
                        self.assertFalse(calls.exists())
                    if failure in ("v2", "cleanup"):
                        self.assertEqual(calls.read_text().splitlines(), ["0.3.23"])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output.read_text(), f"sha256={'0' * 64}\nsource_sha={self.sha}\n")
                    self.assertEqual(calls.read_text().splitlines(), ["0.3.23", "0.4.0-experimental.1"])

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
