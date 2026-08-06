#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER_HUB_API=${DOCKER_HUB_API:-https://hub.docker.com/v2/repositories}

render_images() {
  helm template image-pin-check "$ROOT_DIR" \
    --namespace paperless-ngx-image-pin-check \
    "$@" \
    | awk '$1 == "image:" { gsub(/"/, "", $2); print $2 }' \
    | sort -u
}

pinned_images=$(render_images)
tagged_images=$(render_images \
  --set-string image.digest= \
  --set-string postgresql.image.digest= \
  --set-string valkey.image.tag=9.0.2 \
  --set-string tests.image.digest=)

assert_reference() {
  local collection=$1
  local expected=$2
  local name=$3

  if ! grep -Fqx "$expected" <<<"$collection"; then
    echo "${name}: expected rendered image reference is missing: ${expected}" >&2
    printf '%s\n' "$collection" >&2
    exit 1
  fi
}

if [[ $(sed '/^$/d' <<<"$pinned_images" | wc -l | tr -d ' ') -ne 4 ]]; then
  echo "Expected exactly four unique pinned default images:" >&2
  printf '%s\n' "$pinned_images" >&2
  exit 1
fi

if [[ $(sed '/^$/d' <<<"$tagged_images" | wc -l | tr -d ' ') -ne 4 ]]; then
  echo "Expected exactly four unique tagged default images:" >&2
  printf '%s\n' "$tagged_images" >&2
  exit 1
fi

paperless_tag=$(awk '/^appVersion:/ { gsub(/"/, "", $2); print $2 }' "$ROOT_DIR/Chart.yaml")
paperless_digest=$(awk '
  /^image:/ { in_image=1; next }
  in_image && /^  digest:/ { gsub(/"/, "", $2); print $2; exit }
  in_image && /^[^ ]/ { exit }
' "$ROOT_DIR/values.yaml")
postgres_tag=17.6.0-debian-12-r4
postgres_digest=$(awk '
  /^postgresql:/ { in_postgresql=1; next }
  in_postgresql && /^  image:/ { in_image=1; next }
  in_postgresql && in_image && /^    digest:/ { gsub(/"/, "", $2); print $2; exit }
' "$ROOT_DIR/values.yaml")
valkey_tag=9.0.2
valkey_digest=$(awk '
  /^valkey:/ { in_valkey=1; next }
  in_valkey && /^  image:/ { in_image=1; next }
  in_valkey && in_image && /^    tag:/ {
    gsub(/"/, "", $2)
    sub(/^[^@]+@/, "", $2)
    print $2
    exit
  }
' "$ROOT_DIR/values.yaml")
test_tag=$(awk '
  /^tests:/ { in_tests=1; next }
  in_tests && /^  image:/ { in_image=1; next }
  in_tests && in_image && /^    tag:/ { gsub(/"/, "", $2); print $2; exit }
' "$ROOT_DIR/values.yaml")
test_digest=$(awk '
  /^tests:/ { in_tests=1; next }
  in_tests && /^  image:/ { in_image=1; next }
  in_tests && in_image && /^    digest:/ { gsub(/"/, "", $2); print $2; exit }
' "$ROOT_DIR/values.yaml")

for digest in "$paperless_digest" "$postgres_digest" "$valkey_digest" "$test_digest"; do
  if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Configured image digest is missing or invalid: ${digest:-missing}" >&2
    exit 1
  fi
done

assert_reference "$pinned_images" "ghcr.io/paperless-ngx/paperless-ngx@${paperless_digest}" "Paperless-ngx"
assert_reference "$tagged_images" "ghcr.io/paperless-ngx/paperless-ngx:${paperless_tag}" "Paperless-ngx"
assert_reference "$pinned_images" "docker.io/bitnamilegacy/postgresql@${postgres_digest}" "PostgreSQL"
assert_reference "$tagged_images" "docker.io/bitnamilegacy/postgresql:${postgres_tag}" "PostgreSQL"
assert_reference "$pinned_images" "docker.io/valkey/valkey:${valkey_tag}@${valkey_digest}" "Valkey"
assert_reference "$tagged_images" "docker.io/valkey/valkey:${valkey_tag}" "Valkey"
assert_reference "$pinned_images" "busybox:${test_tag}@${test_digest}" "Helm test"
assert_reference "$tagged_images" "busybox:${test_tag}" "Helm test"

resolve_ghcr_digest() {
  local repository=$1
  local tag=$2
  local token
  local headers
  local digest

  token=$(curl --fail --silent --show-error --location --retry 3 \
    "https://ghcr.io/token?scope=repository%3A${repository//\//%2F}%3Apull&service=ghcr.io" \
    | jq -r '.token // empty')
  [[ -n "$token" ]]

  headers=$(mktemp)
  curl --fail --silent --show-error --head --location --retry 3 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    --output /dev/null \
    --dump-header "$headers" \
    "https://ghcr.io/v2/${repository}/manifests/${tag}"
  digest=$(awk -F': ' 'tolower($1) == "docker-content-digest" { gsub("\\r", "", $2); print $2; exit }' "$headers")
  rm -f "$headers"
  printf '%s\n' "$digest"
}

resolve_dockerhub_digest() {
  local repository=$1
  local tag=$2
  curl --fail --silent --show-error --location --retry 3 \
    "${DOCKER_HUB_API}/${repository}/tags/${tag}" \
    | jq -r '.digest // empty'
}

verify_digest() {
  local name=$1
  local expected=$2
  local actual=$3
  if ! [[ "$actual" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "${name}: registry returned an invalid digest: ${actual:-missing}" >&2
    exit 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "${name}: digest mismatch" >&2
    echo "  configured: ${expected}" >&2
    echo "  registry:   ${actual}" >&2
    exit 1
  fi
  echo "${name}: verified ${expected}"
}

verify_digest "Paperless-ngx ${paperless_tag}" "$paperless_digest" "$(resolve_ghcr_digest paperless-ngx/paperless-ngx "$paperless_tag")"
verify_digest "PostgreSQL ${postgres_tag}" "$postgres_digest" "$(resolve_dockerhub_digest bitnamilegacy/postgresql "$postgres_tag")"
verify_digest "Valkey ${valkey_tag}" "$valkey_digest" "$(resolve_dockerhub_digest valkey/valkey "$valkey_tag")"
verify_digest "BusyBox ${test_tag}" "$test_digest" "$(resolve_dockerhub_digest library/busybox "$test_tag")"
