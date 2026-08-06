#!/usr/bin/env python3

"""Rewrite a Helm chart package as a deterministic, safely ordered archive."""

import argparse
import filecmp
import gzip
import io
import os
from pathlib import Path, PurePosixPath
import tarfile
import tempfile

MAX_MEMBERS = 10_000
MAX_NAME_LENGTH = 4_096
MAX_FILE_SIZE = 64 * 1024 * 1024
MAX_TOTAL_SIZE = 256 * 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail unless the package is already in canonical form",
    )
    parser.add_argument("package", type=Path)
    return parser.parse_args()


def validate_name(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    canonical_name = path.as_posix()
    if (
        not name
        or not path.parts
        or len(name) > MAX_NAME_LENGTH
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
        or any(":" in part for part in path.parts)
        or canonical_name != name
        or "\\" in name
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
    ):
        raise ValueError(f"unsafe archive path: {name!r}")
    return path


def write_normalized(source_path: Path, destination_path: Path) -> None:
    entries = []
    seen_names = set()
    root_names = set()
    total_size = 0

    with tarfile.open(source_path, mode="r:gz") as source:
        members = source.getmembers()
        if len(members) > MAX_MEMBERS:
            raise ValueError(f"chart package has too many entries: {len(members)}")

        for member in members:
            canonical_path = validate_name(member.name)
            canonical_name = canonical_path.as_posix()
            if len(canonical_path.parts) == 1 and not member.isdir():
                raise ValueError(f"archive file is outside the chart root: {canonical_name}")
            if canonical_name in seen_names:
                raise ValueError(f"duplicate archive path: {canonical_name}")
            seen_names.add(canonical_name)
            root_names.add(canonical_path.parts[0])

            if member.isfile():
                if member.size < 0 or member.size > MAX_FILE_SIZE:
                    raise ValueError(
                        f"archive file exceeds size limit: {member.name} ({member.size})"
                    )
                total_size += member.size
                if total_size > MAX_TOTAL_SIZE:
                    raise ValueError(
                        f"chart package exceeds uncompressed size limit: {total_size}"
                    )
                extracted = source.extractfile(member)
                if extracted is None:
                    raise ValueError(f"unable to read archive file: {member.name}")
                data = extracted.read()
            elif member.isdir():
                data = None
            else:
                raise ValueError(
                    f"unsupported archive entry type for {member.name}: {member.type!r}"
                )
            entries.append((canonical_name, member.isdir(), data))

    if not entries:
        raise ValueError("chart package is empty")
    if len(root_names) != 1:
        raise ValueError(f"chart package must contain exactly one root: {root_names}")

    with destination_path.open("wb") as raw_output:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            compresslevel=9,
            fileobj=raw_output,
            mtime=0,
        ) as gzip_output:
            with tarfile.open(
                fileobj=gzip_output,
                mode="w",
                format=tarfile.GNU_FORMAT,
            ) as output:
                for name, is_directory, data in sorted(entries):
                    normalized = tarfile.TarInfo(name)
                    normalized.mtime = 0
                    normalized.uid = 0
                    normalized.gid = 0
                    normalized.uname = ""
                    normalized.gname = ""
                    normalized.pax_headers = {}
                    if is_directory:
                        normalized.mode = 0o755
                        normalized.type = tarfile.DIRTYPE
                        normalized.size = 0
                        output.addfile(normalized)
                    else:
                        assert data is not None
                        normalized.mode = 0o644
                        normalized.type = tarfile.REGTYPE
                        normalized.size = len(data)
                        output.addfile(normalized, io.BytesIO(data))


def main() -> int:
    args = parse_args()
    package = args.package.resolve()
    if not package.is_file() or package.stat().st_size == 0:
        raise ValueError(f"chart package does not exist or is empty: {package}")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{package.name}.",
        suffix=".tmp",
        dir=package.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        write_normalized(package, temporary)
        temporary.chmod(package.stat().st_mode & 0o777)
        if args.check:
            if not filecmp.cmp(package, temporary, shallow=False):
                raise ValueError(f"chart package is not canonical: {package}")
            print(f"Verified canonical chart package: {package}")
        else:
            os.replace(temporary, package)
            print(f"Normalized chart package: {package}")
    finally:
        temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
