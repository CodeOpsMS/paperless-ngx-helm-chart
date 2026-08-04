#!/usr/bin/env bash

set -euo pipefail

repository_root=${1:-.}
cd "$repository_root"

require_text() {
  local text=$1
  local file=$2
  if ! grep -Fq "$text" "$file"; then
    echo "Missing expected metadata in ${file}: ${text}"
    exit 1
  fi
}

test -s NOTICE
test -s LICENSES/CodeOpsMS-MIT.txt
test -s .mailmap
test -s artifacthub-repo.yml
test -s renovate.json
test -s .github/dependabot.yml
test -s .github/workflows/auto-update-paperless.yml

if [[ -e LICENSE || -e LICENSE.md || -e LICENSE.txt ]]; then
  echo "A root license would incorrectly describe the combined chart"
  exit 1
fi

if grep -q 'artifacthub.io/license' Chart.yaml; then
  echo "Chart.yaml must not claim a package-wide license while upstream rights are unresolved"
  exit 1
fi

if grep -Eq 'img\.shields\.io/badge/(Version|AppVersion)-[0-9]' README.md; then
  echo "README contains a hard-coded release badge"
  exit 1
fi

require_text 'img.shields.io/github/v/release/CodeOpsMS/paperless-ngx-helm-chart' README.md
require_text 'artifacthub.io/packages/helm/paperless/paperless-ngx' README.md
require_text '| Repository name | `paperless` |' README.md
require_text '| Display name | `Paperless-ngx` |' README.md

require_text 'name: CodeOpsMS' Chart.yaml
require_text '| CodeOpsMS |' README.md
require_text 'name: CodeOpsMS' artifacthub-repo.yml
require_text 'repositoryID: 9d5a07d6-7540-44fe-a74c-d98953891494' artifacthub-repo.yml
require_text 'CodeOpsMS <111311779+CodeOpsMS@users.noreply.github.com>' .mailmap

if grep -Eq 'Manfred|M\.Lämmerzahl' Chart.yaml README.md artifacthub-repo.yml; then
  echo "Project-facing maintainer metadata must use CodeOpsMS"
  exit 1
fi

jq empty renovate.json
require_text '"helmv3"' renovate.json
require_text '"custom.regex"' renovate.json
require_text 'package-ecosystem: github-actions' .github/dependabot.yml

echo "Repository documentation, licensing, and update metadata are consistent"
