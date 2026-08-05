#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELM_BIN=${HELM_BIN:-helm}
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

decode_base64() {
  local encoded=$1

  if decoded=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null); then
    printf '%s' "$decoded"
  else
    printf '%s' "$encoded" | base64 -D
  fi
}

extract_name() {
  local source=$1
  local rendered=$2

  awk -v source="# Source: ${source}" '
    $0 == source { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && /^metadata:$/ { in_metadata=1; next }
    in_document && in_metadata && /^  name:/ {
      value=$2
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$rendered"
}

extract_secret_value() {
  local key=$1
  local rendered=$2

  awk -v key="$key:" '
    $0 == "# Source: paperless-ngx/templates/secrets.yaml" { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && /^data:$/ { in_data=1; next }
    in_document && in_data && $1 == key {
      value=$2
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$rendered"
}

verify_case() {
  local release=$1
  shift
  local rendered="$RENDER_DIR/${release}.yaml"
  local database_service
  local database_host
  local redis_service
  local redis_url
  local redis_host

  "$HELM_BIN" template "$release" "$ROOT_DIR" \
    --namespace "$release" \
    "$@" \
    >"$rendered"

  database_service=$(extract_name \
    "paperless-ngx/charts/postgresql/templates/primary/svc.yaml" \
    "$rendered")
  redis_service=$(extract_name \
    "paperless-ngx/charts/valkey/templates/service.yaml" \
    "$rendered")
  database_host=$(decode_base64 "$(extract_secret_value PAPERLESS_DBHOST "$rendered")")
  redis_url=$(decode_base64 "$(extract_secret_value PAPERLESS_REDIS "$rendered")")
  redis_host=${redis_url#redis://}
  redis_host=${redis_host%%:*}

  if [[ -z "$database_service" || -z "$redis_service" ]]; then
    echo "Unable to locate dependency Services for release ${release}" >&2
    exit 1
  fi
  if [[ "$database_host" != "$database_service" ]]; then
    echo "PostgreSQL discovery mismatch for ${release}: ${database_host} != ${database_service}" >&2
    exit 1
  fi
  if [[ "$redis_host" != "$redis_service" ]]; then
    echo "Valkey discovery mismatch for ${release}: ${redis_host} != ${redis_service}" >&2
    exit 1
  fi

  echo "Verified ${release}: PostgreSQL=${database_host}, Valkey=${redis_host}"
}

verify_case paperless-fresh
verify_case paperless-overrides \
  --set-string postgresql.fullnameOverride=paperless-database \
  --set-string valkey.fullnameOverride=paperless-broker
verify_case paperless-replication \
  --set-string postgresql.nameOverride=database \
  --set-string postgresql.architecture=replication \
  --set-string postgresql.primary.name=leader \
  --set-string valkey.nameOverride=broker
verify_case paperless-production-eu-west-upgrade-validation-1234
