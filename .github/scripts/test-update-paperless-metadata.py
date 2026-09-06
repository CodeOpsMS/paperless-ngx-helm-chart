#!/usr/bin/env python3
"""Regressions for automation that previously rewrote historical bug reports."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("updater", Path(__file__).with_name("update-paperless-metadata.py"))
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)
OLD_DIGEST = "sha256:" + "a" * 64
NEW_DIGEST = "sha256:" + "b" * 64


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        (self.root / "tests").mkdir()
        (self.root / ".github/pages").mkdir(parents=True)
        (self.root / "Chart.yaml").write_text(f'''version: "0.4.0-experimental.1"
appVersion: "3.0.5"
annotations:
  artifacthub.io/prerelease: "true"
  artifacthub.io/containsSecurityUpdates: "true"
  artifacthub.io/changes: |
    - kind: security
      description: Fixed a security issue in Paperless 3.0.5
    - kind: fixed
      description: Reject SEARCH_LANGUAGE for the 3.0.5 startup bug
  artifacthub.io/images: |
    - name: Paperless
      image: {updater.IMAGE}@{OLD_DIGEST}
''')
        (self.root / "values.yaml").write_text(f'''image:
  digest: "{OLD_DIGEST}"
dependency:
  image:
    digest: "{OLD_DIGEST}"
''')
        (self.root / "tests/deployment_test.yaml").write_text(
            f"image: {updater.IMAGE}@{OLD_DIGEST}\nimage: {updater.IMAGE}:3.0.5\n"
            "historical: Paperless 3.0.5 lacked this feature\n"
        )
        (self.root / ".github/pages/index.html").write_text(
            "Stable 0.3.23; preview 0.4.0-experimental.1; --version 0.4.0-experimental.1"
        )
        self.history = "Known issue in 3.0.5; verified 0.4.0-experimental.1"
        for name in ("UPGRADE-0.4.md", "TESTING.md", "values.schema.json"):
            (self.root / name).write_text(self.history)

    def test_updates_current_metadata_but_preserves_history_and_stable_channel(self):
        self.assertEqual(updater.update(self.root, "3.1.3", NEW_DIGEST), "0.4.0-experimental.2")
        chart = (self.root / "Chart.yaml").read_text()
        self.assertIn('appVersion: "3.1.3"', chart)
        self.assertIn('artifacthub.io/prerelease: "true"', chart)
        self.assertIn('artifacthub.io/containsSecurityUpdates: "false"', chart)
        self.assertNotIn("kind: security", chart)
        self.assertNotIn("startup bug", chart)
        self.assertIn("from 3.0.5 to 3.1.3", chart)
        self.assertIn(f"{updater.IMAGE}@{NEW_DIGEST}", chart)
        values = (self.root / "values.yaml").read_text()
        self.assertEqual(values.count(OLD_DIGEST), 1)
        self.assertEqual(values.count(NEW_DIGEST), 1)
        tests = (self.root / "tests/deployment_test.yaml").read_text()
        self.assertIn(f"{updater.IMAGE}:3.1.3\n", tests)
        self.assertIn("Paperless 3.0.5 lacked", tests)
        pages = (self.root / ".github/pages/index.html").read_text()
        self.assertIn("Stable 0.3.23", pages)
        self.assertEqual(pages.count("0.4.0-experimental.2"), 2)
        for name in ("UPGRADE-0.4.md", "TESTING.md", "values.schema.json"):
            self.assertEqual((self.root / name).read_text(), self.history)

    def test_digest_only_update_stays_experimental(self):
        updater.update(self.root, "3.0.5", NEW_DIGEST)
        chart = (self.root / "Chart.yaml").read_text()
        self.assertIn("after upstream republishing", chart)
        self.assertIn('version: "0.4.0-experimental.2"', chart)

    def test_invalid_targets_leave_files_unchanged(self):
        before = (self.root / "Chart.yaml").read_bytes()
        for version, digest in (("4.0.0", NEW_DIGEST), ("3.0.4", NEW_DIGEST),
                                ("3.2.0-rc.1", NEW_DIGEST), ("3.1.3", "invalid"),
                                ("3.0.5", OLD_DIGEST)):
            with self.subTest(version=version, digest=digest):
                with self.assertRaises(ValueError):
                    updater.update(self.root, version, digest)
                self.assertEqual((self.root / "Chart.yaml").read_bytes(), before)

    def test_ambiguous_expectation_does_not_partially_update(self):
        (self.root / "tests/deployment_test.yaml").write_text("missing image expectations\n")
        before = (self.root / "Chart.yaml").read_bytes()
        with self.assertRaises(ValueError):
            updater.update(self.root, "3.1.3", NEW_DIGEST)
        self.assertEqual((self.root / "Chart.yaml").read_bytes(), before)

    def test_stable_chart_bump_and_unsupported_channel(self):
        self.assertEqual(updater.next_chart_version("0.3.23"), "0.3.24")
        with self.assertRaises(ValueError):
            updater.next_chart_version("0.4.0-rc.1")


if __name__ == "__main__":
    unittest.main()
