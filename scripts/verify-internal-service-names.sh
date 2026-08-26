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

extract_service_port() {
  local source=$1
  local rendered=$2

  awk -v source="# Source: ${source}" '
    $0 == source { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && $1 == "port:" {
      print $2
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

extract_deployment_password_ref() {
  local field=$1
  local rendered=$2

  awk -v field="${field}:" '
    $0 == "# Source: paperless-ngx/templates/deployment.yaml" { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && $2 == "name:" && $3 == "PAPERLESS_DBPASS" { in_password=1; next }
    in_password && $1 == field {
      value=$2
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$rendered"
}

extract_postgresql_env() {
  local name=$1
  local rendered=$2

  awk -v name="$name" '
    $0 == "# Source: paperless-ngx/charts/postgresql/templates/primary/statefulset.yaml" { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && $2 == "name:" && $3 == name { in_env=1; next }
    in_env && $1 == "value:" {
      value=$0
      sub(/^[[:space:]]*value:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$rendered"
}

extract_postgresql_secret_mount() {
  local rendered=$1

  awk '
    $0 == "# Source: paperless-ngx/charts/postgresql/templates/primary/statefulset.yaml" { in_document=1; next }
    in_document && /^---$/ { exit }
    in_document && $2 == "name:" && $3 == "postgresql-password" { in_volume=1; next }
    in_volume && $1 == "secretName:" {
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
  local database_port
  local database_service_port
  local redis_service
  local redis_url
  local redis_host
  local paperless_database
  local paperless_username
  local paperless_password_secret
  local paperless_password_key
  local postgresql_database
  local postgresql_username
  local postgresql_password_file
  local postgresql_password_key
  local postgresql_password_secret

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
  database_port=$(decode_base64 "$(extract_secret_value PAPERLESS_DBPORT "$rendered")")
  database_port=${database_port:-5432}
  database_service_port=$(extract_service_port \
    "paperless-ngx/charts/postgresql/templates/primary/svc.yaml" \
    "$rendered")
  redis_url=$(decode_base64 "$(extract_secret_value PAPERLESS_REDIS "$rendered")")
  redis_host=${redis_url#redis://}
  redis_host=${redis_host%%:*}
  paperless_database=$(decode_base64 "$(extract_secret_value PAPERLESS_DBNAME "$rendered")")
  paperless_username=$(decode_base64 "$(extract_secret_value PAPERLESS_DBUSER "$rendered")")
  paperless_password_secret=$(extract_deployment_password_ref name "$rendered")
  paperless_password_key=$(extract_deployment_password_ref key "$rendered")
  postgresql_database=$(extract_postgresql_env POSTGRES_DATABASE "$rendered")
  postgresql_username=$(extract_postgresql_env POSTGRES_USER "$rendered")
  postgresql_database=${postgresql_database:-postgres}
  postgresql_username=${postgresql_username:-postgres}
  postgresql_password_file=$(extract_postgresql_env POSTGRES_PASSWORD_FILE "$rendered")
  postgresql_password_key=${postgresql_password_file##*/}
  postgresql_password_secret=$(extract_postgresql_secret_mount "$rendered")

  if [[ -z "$database_service" || -z "$redis_service" ]]; then
    echo "Unable to locate dependency Services for release ${release}" >&2
    exit 1
  fi
  if [[ "$database_host" != "$database_service" ]]; then
    echo "PostgreSQL discovery mismatch for ${release}: ${database_host} != ${database_service}" >&2
    exit 1
  fi
  if [[ "$database_port" != "$database_service_port" ]]; then
    echo "PostgreSQL port mismatch for ${release}: ${database_port} != ${database_service_port}" >&2
    exit 1
  fi
  if [[ "$redis_host" != "$redis_service" ]]; then
    echo "Valkey discovery mismatch for ${release}: ${redis_host} != ${redis_service}" >&2
    exit 1
  fi
  if [[ "$paperless_database" != "$postgresql_database" ]]; then
    echo "PostgreSQL database mismatch for ${release}: ${paperless_database} != ${postgresql_database}" >&2
    exit 1
  fi
  if [[ "$paperless_username" != "$postgresql_username" ]]; then
    echo "PostgreSQL username mismatch for ${release}: ${paperless_username} != ${postgresql_username}" >&2
    exit 1
  fi
  if [[ "$paperless_password_secret" != "$postgresql_password_secret" ]]; then
    echo "PostgreSQL password Secret mismatch for ${release}: ${paperless_password_secret} != ${postgresql_password_secret}" >&2
    exit 1
  fi
  if [[ "$paperless_password_key" != "$postgresql_password_key" ]]; then
    echo "PostgreSQL password key mismatch for ${release}: ${paperless_password_key} != ${postgresql_password_key}" >&2
    exit 1
  fi

  echo "Verified ${release}: PostgreSQL=${database_host}/${paperless_database}/${paperless_username}, Valkey=${redis_host}"
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
verify_case paperless-global-service \
  --set-string global.postgresql.fullnameOverride=paperless-global-database \
  --set global.postgresql.service.ports.postgresql=5543
verify_case paperless-global-credentials \
  --set-string global.postgresql.auth.database=paperless_ci \
  --set-string global.postgresql.auth.username=paperless_ci \
  --set-string global.postgresql.auth.existingSecret=paperless-postgresql-credentials \
  --set-string global.postgresql.auth.secretKeys.userPasswordKey=user-password
verify_case paperless-raw-username \
  --set-json 'global.postgresql.auth={"database":"paperless","username":"{{ .Release.Name }}_user"}'
verify_case paperless-postgres-admin \
  --set-string postgresql.auth.database=postgres \
  --set-string postgresql.auth.username=postgres \
  --set-string postgresql.auth.existingSecret=paperless-postgresql-admin \
  --set-string postgresql.auth.secretKeys.adminPasswordKey=admin-password
