#!/usr/bin/env bash

set -euo pipefail

package=${1:?Usage: check-chart-package.sh CHART_PACKAGE}
chart_name=$(helm show chart "$package" | awk '/^name:/ { print $2 }')
chart_metadata=$(mktemp)
contents=$(mktemp)
trap 'rm -f "$chart_metadata" "$contents"' EXIT

test -n "$chart_name"
test -s "$package"
helm show chart "$package" >"$chart_metadata"
tar -tzf "$package" >"$contents"

grep -qx "${chart_name}/NOTICE" "$contents"
grep -qx "${chart_name}/LICENSES/CodeOpsMS-MIT.txt" "$contents"

if grep -Eq "^${chart_name}/LICENSE([.][^/]*)?$" "$contents"; then
  echo "The packaged chart must not declare a package-wide root license"
  exit 1
fi

if grep -q 'artifacthub.io/license' "$chart_metadata"; then
  echo "The chart must not declare a package-wide Artifact Hub license"
  exit 1
fi

if grep -q "^${chart_name}/.github/" "$contents"; then
  echo "The packaged chart must not contain GitHub workflow files"
  exit 1
fi

if grep -qx "${chart_name}/renovate.json" "$contents"; then
  echo "The packaged chart must not contain repository automation config"
  exit 1
fi

if grep -qx "${chart_name}/.mailmap" "$contents"; then
  echo "The packaged chart must not contain repository identity mappings"
  exit 1
fi

if grep -Eq "^${chart_name}/scripts/" "$contents"; then
  echo "The packaged chart must not contain repository-only scripts"
  exit 1
fi
