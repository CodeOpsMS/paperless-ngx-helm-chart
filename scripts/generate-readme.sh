#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELM_DOCS_VERSION=1.14.2
HELM_DOCS_BIN=${HELM_DOCS_BIN:-}

if [[ -z "$HELM_DOCS_BIN" ]] && command -v helm-docs >/dev/null 2>&1; then
  HELM_DOCS_BIN=$(command -v helm-docs)
fi

if [[ -z "$HELM_DOCS_BIN" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
      archive="helm-docs_${HELM_DOCS_VERSION}_Darwin_arm64.tar.gz"
      expected="2d8399db5b33d240d5f8985241bcf5483563150b968e3229823822979f3e4b8b"
      ;;
    Linux-x86_64)
      archive="helm-docs_${HELM_DOCS_VERSION}_Linux_x86_64.tar.gz"
      expected="a8cf72ada34fad93285ba2a452b38bdc5bd52cc9a571236244ec31022928d6cc"
      ;;
    *)
      echo "Unsupported helm-docs bootstrap platform: $(uname -s)-$(uname -m)" >&2
      echo "Install helm-docs ${HELM_DOCS_VERSION} or set HELM_DOCS_BIN." >&2
      exit 1
      ;;
  esac

  download_dir=$(mktemp -d)
  trap 'rm -rf "$download_dir"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/norwoodj/helm-docs/releases/download/v${HELM_DOCS_VERSION}/${archive}" \
    --output "$download_dir/$archive"

  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$download_dir/$archive" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$download_dir/$archive" | awk '{print $1}')
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "helm-docs archive checksum mismatch" >&2
    exit 1
  fi

  tar -xzf "$download_dir/$archive" -C "$download_dir"
  HELM_DOCS_BIN="$download_dir/helm-docs"
fi

"$HELM_DOCS_BIN" \
  --chart-search-root "$ROOT_DIR" \
  --template-files=_docs.gotmpl \
  --output-file=README.md
