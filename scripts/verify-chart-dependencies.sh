#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

verify_archive() {
  local archive=$1
  local expected=$2
  local path="${ROOT_DIR}/charts/${archive}"
  local actual

  if [[ ! -s "$path" ]]; then
    echo "Missing chart dependency archive: charts/${archive}" >&2
    return 1
  fi
  actual=$(sha256_file "$path")
  if [[ "$actual" != "$expected" ]]; then
    echo "Chart dependency checksum mismatch: charts/${archive}" >&2
    echo "expected=${expected}" >&2
    echo "actual=${actual}" >&2
    return 1
  fi
  echo "Verified charts/${archive}: ${actual}"
}

verify_archive \
  postgresql-16.7.27.tgz \
  d7d0f7d0342d56504f3bb2f77867e0b7173f6322f11266b74e2d0eda53365901
verify_archive \
  valkey-0.9.4.tgz \
  a685b802426be48519569389e4e6b221e21376bece84bb8b331720e54a8c21c9

expected_archives=2
archive_count=0
for archive in "${ROOT_DIR}"/charts/*.tgz; do
  [[ -e "$archive" ]] || continue
  archive_count=$((archive_count + 1))
done
if [[ "$archive_count" -ne "$expected_archives" ]]; then
  echo "Expected ${expected_archives} chart dependency archives, found ${archive_count}" >&2
  exit 1
fi
