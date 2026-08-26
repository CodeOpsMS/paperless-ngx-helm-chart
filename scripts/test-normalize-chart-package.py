#!/usr/bin/env python3

"""Regression tests for deterministic and safe Helm package normalization."""

import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("normalize-chart-package.py")
SPEC = importlib.util.spec_from_file_location("paperless_normalizer", SCRIPT)
NORMALIZER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(NORMALIZER)


def write_archive(path, entries):
    with tarfile.open(path, "w:gz") as archive:
        for name, data, mode, entry_type in entries:
            member = tarfile.TarInfo(name)
            member.uid = 123
            member.gid = 456
            member.mtime = 987654321
            member.mode = mode
            member.type = entry_type
            if data is None:
                archive.addfile(member)
            else:
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))


class PackageNormalizerTest(unittest.TestCase):
    def test_rejects_unsafe_names(self):
        unsafe_names = (
            "",
            ".",
            "./paperless-ngx/Chart.yaml",
            "/paperless-ngx/Chart.yaml",
            "paperless-ngx//Chart.yaml",
            "paperless-ngx/../escape",
            "paperless-ngx/..\\escape",
            "C:/escape",
            "paperless-ngx/newline\nname",
        )
        for name in unsafe_names:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    NORMALIZER.validate_name(name)

    def test_accepts_canonical_chart_names(self):
        for name in ("paperless-ngx", "paperless-ngx/Chart.yaml"):
            with self.subTest(name=name):
                self.assertEqual(NORMALIZER.validate_name(name).as_posix(), name)

    def test_canonicalizes_order_metadata_and_modes(self):
        entries = [
            ("paperless-ngx", None, 0o700, tarfile.DIRTYPE),
            ("paperless-ngx/Chart.yaml", b"name: paperless-ngx\n", 0o600, tarfile.REGTYPE),
            ("paperless-ngx/values.yaml", b"replicaCount: 1\n", 0o777, tarfile.REGTYPE),
        ]
        with tempfile.TemporaryDirectory() as temporary_dir:
            root = Path(temporary_dir)
            first_raw = root / "first.tgz"
            second_raw = root / "second.tgz"
            first = root / "first.normalized.tgz"
            second = root / "second.normalized.tgz"
            repeated = root / "repeated.normalized.tgz"
            write_archive(first_raw, entries)
            write_archive(second_raw, list(reversed(entries)))

            NORMALIZER.write_normalized(first_raw, first)
            NORMALIZER.write_normalized(second_raw, second)
            NORMALIZER.write_normalized(first, repeated)

            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.read_bytes(), repeated.read_bytes())
            with tarfile.open(first, "r:gz") as archive:
                members = archive.getmembers()
            self.assertEqual(
                [member.name for member in members],
                sorted(member.name for member in members),
            )
            self.assertEqual([member.mode for member in members], [0o755, 0o644, 0o644])
            self.assertTrue(
                all(member.uid == 0 and member.gid == 0 and member.mtime == 0 for member in members)
            )

    def test_rejects_duplicate_and_non_regular_entries(self):
        unsafe_cases = (
            [
                ("paperless-ngx", None, 0o755, tarfile.DIRTYPE),
                ("paperless-ngx/Chart.yaml", b"one", 0o644, tarfile.REGTYPE),
                ("paperless-ngx/Chart.yaml", b"two", 0o644, tarfile.REGTYPE),
            ],
            [
                ("paperless-ngx", None, 0o755, tarfile.DIRTYPE),
                ("paperless-ngx/link", None, 0o777, tarfile.SYMTYPE),
            ],
            [
                ("paperless-ngx", None, 0o755, tarfile.DIRTYPE),
                ("other-chart", None, 0o755, tarfile.DIRTYPE),
            ],
        )
        with tempfile.TemporaryDirectory() as temporary_dir:
            root = Path(temporary_dir)
            for index, entries in enumerate(unsafe_cases):
                with self.subTest(index=index):
                    source = root / f"unsafe-{index}.tgz"
                    output = root / f"unsafe-{index}.normalized.tgz"
                    write_archive(source, entries)
                    with self.assertRaises(ValueError):
                        NORMALIZER.write_normalized(source, output)


if __name__ == "__main__":
    unittest.main()
