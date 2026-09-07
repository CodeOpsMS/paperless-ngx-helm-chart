#!/usr/bin/env python3
"""Prepare current release metadata without rewriting historical upgrade facts."""

import argparse
from pathlib import Path
import re


IMAGE = "ghcr.io/paperless-ngx/paperless-ngx"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DIGEST = r"sha256:[0-9a-f]{64}"


def field(text: str, name: str) -> str:
    matches = re.findall(rf'^{re.escape(name)}: "?([^"\n]+)"?$', text, re.M)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {name} field")
    return matches[0]


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"Expected exactly one occurrence of {before!r}")
    return text.replace(before, after, 1)


def next_chart_version(version: str) -> str:
    match = re.fullmatch(rf"({VERSION})(?:-experimental\.([1-9][0-9]*))?", version)
    if match is None:
        raise ValueError(f"Unsupported chart version: {version}")
    if match[2] is not None:
        return f"{match[1]}-experimental.{int(match[2]) + 1}"
    major, minor, patch = map(int, match[1].split("."))
    return f"{major}.{minor}.{patch + 1}"


def update(root: Path, version: str, digest: str) -> str:
    if re.fullmatch(VERSION, version) is None or re.fullmatch(DIGEST, digest) is None:
        raise ValueError("A stable app version and SHA-256 image digest are required")
    chart_path = root / "Chart.yaml"
    values_path = root / "values.yaml"
    test_path = root / "tests/deployment_test.yaml"
    pages_path = root / ".github/pages/index.html"
    chart = chart_path.read_text()
    values = values_path.read_text()
    tests = test_path.read_text()
    pages = pages_path.read_text()
    old_version = field(chart, "appVersion")
    old_chart_version = field(chart, "version")
    if re.fullmatch(VERSION, old_version) is None:
        raise ValueError("Current appVersion must be a stable version")
    old_parts = tuple(map(int, old_version.split(".")))
    new_parts = tuple(map(int, version.split(".")))
    if old_parts[0] != new_parts[0] or new_parts < old_parts:
        raise ValueError("Major upgrades and downgrades require a manual migration PR")
    new_chart_version = next_chart_version(old_chart_version)
    image_block = re.search(r"(?ms)^image:\n(?P<body>.*?)(?=^\S|\Z)", values)
    if image_block is None:
        raise ValueError("Missing top-level image configuration")
    old_digest = field(image_block["body"], "  digest")
    if re.fullmatch(DIGEST, old_digest) is None:
        raise ValueError("Current Paperless image digest is invalid")
    if old_version == version and old_digest == digest:
        raise ValueError("The application version and image digest are already current")
    security_field = "  artifacthub.io/containsSecurityUpdates"
    security_status = field(chart, security_field)
    if security_status not in ("true", "false"):
        raise ValueError("Invalid Artifact Hub security update status")

    chart = re.sub(r'^version: .*$', f'version: "{new_chart_version}"', chart, flags=re.M)
    chart = re.sub(r'^appVersion: .*$', f'appVersion: "{version}"', chart, flags=re.M)
    chart = replace_once(chart, f"{IMAGE}@{old_digest}", f"{IMAGE}@{digest}")
    chart = re.sub(rf'^{re.escape(security_field)}: .*$', f'{security_field}: "false"', chart, flags=re.M)
    description = (
        f"Upgrade Paperless-ngx from {old_version} to {version}; review upstream compatibility and security changes"
        if version != old_version
        else f"Refresh the immutable Paperless-ngx {version} image digest after upstream republishing"
    )
    chart, count = re.subn(
        r"(?m)^  artifacthub\.io/changes: \|\n(?:^    .*\n|^\n)*",
        f"  artifacthub.io/changes: |\n    - kind: changed\n      description: {description}\n",
        chart,
    )
    if count != 1:
        raise ValueError("Expected exactly one Artifact Hub changelog")
    image_body = replace_once(image_block["body"], old_digest, digest)
    values = values[:image_block.start("body")] + image_body + values[image_block.end("body"):]
    tests = replace_once(tests, f"{IMAGE}@{old_digest}", f"{IMAGE}@{digest}")
    tests = replace_once(tests, f"{IMAGE}:{old_version}\n", f"{IMAGE}:{version}\n")
    if old_chart_version not in pages:
        raise ValueError("The Pages installer does not mention the current chart")
    pages = pages.replace(old_chart_version, new_chart_version)

    # Validate every transformation before writing any file. Upgrade documentation,
    # schema guards and historical test evidence are intentionally untouched.
    for path, content in ((chart_path, chart), (values_path, values), (test_path, tests), (pages_path, pages)):
        path.write_text(content)
    return new_chart_version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--version", required=True)
    parser.add_argument("--digest", required=True)
    args = parser.parse_args()
    try:
        print(f"Prepared chart {update(args.root, args.version, args.digest)}")
    except ValueError as error:
        parser.error(str(error))
