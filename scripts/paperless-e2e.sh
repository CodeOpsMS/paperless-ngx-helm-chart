#!/usr/bin/env bash

set -euo pipefail

MODE=${1:?Usage: paperless-e2e.sh fresh|upgrade CANDIDATE_CHART}
CANDIDATE_CHART=${2:?Usage: paperless-e2e.sh fresh|upgrade CANDIDATE_CHART}

if [[ "$MODE" != "fresh" && "$MODE" != "upgrade" ]]; then
  echo "Unsupported E2E mode: $MODE" >&2
  exit 2
fi

KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
KUBE_CONTEXT=${KUBE_CONTEXT:-}
KUBE_INSECURE_SKIP_TLS_VERIFY=${KUBE_INSECURE_SKIP_TLS_VERIFY:-false}
HELM_BIN=${HELM_BIN:-helm}
BASE_HELM_BIN=${BASE_HELM_BIN:-$HELM_BIN}
NAMESPACE=${NAMESPACE:-paperless-ngx-e2e}
RELEASE=${RELEASE:-paperless-e2e}
LOCAL_PORT=${LOCAL_PORT:-18000}
BASE_CHART_VERSION=${BASE_CHART_VERSION:-0.3.23}
BASE_CHART_REPOSITORY=${BASE_CHART_REPOSITORY:-https://codeopsms.github.io/paperless-ngx-helm-chart/}
BASE_CHART_PACKAGE=${BASE_CHART_PACKAGE:-}
CLEANUP_NAMESPACE=${CLEANUP_NAMESPACE:-false}
PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER:-e2e-admin}
PAPERLESS_ADMIN_PASSWORD=${PAPERLESS_ADMIN_PASSWORD:-paperless-e2e-password}
PAPERLESS_ADMIN_MAIL=${PAPERLESS_ADMIN_MAIL:-e2e@example.invalid}
API_ACCEPT=application/json
PORT_FORWARD_PID=
API_TOKEN=
DOCUMENT_ID=
TAG_ID=
CORRESPONDENT_ID=
DOCUMENT_TYPE_ID=
CUSTOM_FIELD_ID=
SAVED_VIEW_ID=
ORIGINAL_DOCUMENT_HASH=
EXPECTED_SAVED_VIEW_QUERY='notes.note:E2E AND custom_fields.value:E2E'
EXPECTED_PAPERLESS_VERSION=$(
  "$HELM_BIN" show chart "$CANDIDATE_CHART" \
    | awk '/^appVersion:/ { gsub(/"/, "", $2); print $2 }'
)
if ! [[ "$EXPECTED_PAPERLESS_VERSION" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
  echo "Candidate does not declare a stable Paperless 3 appVersion: ${EXPECTED_PAPERLESS_VERSION:-missing}" >&2
  exit 1
fi

common_values=(
  --set-string config.url=http://paperless.local
  --set-string env.PAPERLESS_TIME_ZONE=UTC
  --set env.PAPERLESS_CONSUMER_DELETE_DUPLICATES=true
  --set-string persistence.size=1Gi
  --set-string postgresql.primary.persistence.size=2Gi
)

kubectl_args=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  kubectl_args+=(--context "$KUBE_CONTEXT")
fi
if [[ "$KUBE_INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
  kubectl_args+=(--insecure-skip-tls-verify=true)
fi

kube() {
  "$KUBECTL_BIN" "${kubectl_args[@]}" "$@"
}

stop_port_forward() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    PORT_FORWARD_PID=
  fi
}

diagnostics() {
  echo "--- Kubernetes resources" >&2
  kube get all,pvc -n "$NAMESPACE" -o wide >&2 || true
  echo "--- Kubernetes events" >&2
  kube get events -n "$NAMESPACE" --sort-by=.lastTimestamp >&2 || true
  echo "--- Paperless logs" >&2
  kube logs -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx --all-containers --tail=300 >&2 || true
}

finish() {
  local status=$?
  trap - EXIT
  stop_port_forward
  if [[ $status -ne 0 ]]; then
    diagnostics
  fi
  if [[ "$CLEANUP_NAMESPACE" == "true" ]]; then
    kube delete namespace "$NAMESPACE" --wait=true >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap finish EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

app_deployment() {
  kube get deployment -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}'
}

app_pod() {
  kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}'
}

app_service() {
  kube get service -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}'
}

wait_for_application() {
  local deployment
  deployment=$(app_deployment)
  kube rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=30m
  kube wait pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx \
    --for=condition=Ready --timeout=30m
}

start_port_forward() {
  local service
  local attempt
  stop_port_forward
  service=$(app_service)
  kube port-forward -n "$NAMESPACE" service/"$service" "${LOCAL_PORT}:80" \
    >/tmp/paperless-e2e-port-forward.log 2>&1 &
  PORT_FORWARD_PID=$!
  for attempt in $(seq 1 120); do
    if curl --silent --output /dev/null --header 'Host: paperless.local' \
      "http://127.0.0.1:${LOCAL_PORT}/"; then
      return 0
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      cat /tmp/paperless-e2e-port-forward.log >&2
      return 1
    fi
    sleep 2
  done
  echo "Paperless did not become reachable through the port-forward" >&2
  return 1
}

api_request() {
  local method=$1
  local path=$2
  shift 2
  local auth_args=()
  if [[ -n "$API_TOKEN" ]]; then
    auth_args=(-H "Authorization: Token ${API_TOKEN}")
  fi
  curl --fail-with-body --silent --show-error \
    -X "$method" \
    -H 'Host: paperless.local' \
    -H "Accept: ${API_ACCEPT}" \
    "${auth_args[@]}" \
    "$@" \
    "http://127.0.0.1:${LOCAL_PORT}${path}"
}

authenticate() {
  local pod
  pod=$(app_pod)
  kube exec -n "$NAMESPACE" "$pod" -- \
    env \
      PAPERLESS_ADMIN_USER="$PAPERLESS_ADMIN_USER" \
      PAPERLESS_ADMIN_PASSWORD="$PAPERLESS_ADMIN_PASSWORD" \
      PAPERLESS_ADMIN_MAIL="$PAPERLESS_ADMIN_MAIL" \
      python3 manage.py manage_superuser

  API_TOKEN=$(api_request POST /api/token/ \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${PAPERLESS_ADMIN_USER}" \
    --data-urlencode "password=${PAPERLESS_ADMIN_PASSWORD}" \
    | jq -r '.token // empty')
  if [[ -z "$API_TOKEN" ]]; then
    echo "Paperless token endpoint did not return a token" >&2
    exit 1
  fi
}

json_results() {
  jq -c 'if type == "array" then . else (.results // []) end'
}

wait_for_document() {
  local attempt
  local response
  for attempt in $(seq 1 180); do
    response=$(api_request GET '/api/documents/?page_size=100')
    DOCUMENT_ID=$(jq -r '
      (if type == "array" then . else (.results // []) end)
      | map(select(.title == "E2E Upgrade Document"))
      | first
      | .id // empty
    ' <<<"$response")
    if [[ -n "$DOCUMENT_ID" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Uploaded E2E document was not consumed" >&2
  return 1
}

seed_data() {
  local fixture=/tmp/paperless-e2e-document.pdf
  local upload_response
  local saved_view_query
  local saved_view_response

  curl --fail --silent --show-error --location --retry 3 \
    https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v2.20.15/src/documents/tests/samples/simple.pdf \
    --output "$fixture"
  [[ -s "$fixture" ]]

  TAG_ID=$(api_request POST /api/tags/ \
    -H 'Content-Type: application/json' \
    --data '{"name":"E2E Upgrade Tag","color":"#1f78b4"}' | jq -r '.id')
  CORRESPONDENT_ID=$(api_request POST /api/correspondents/ \
    -H 'Content-Type: application/json' \
    --data '{"name":"E2E Upgrade Correspondent"}' | jq -r '.id')
  DOCUMENT_TYPE_ID=$(api_request POST /api/document_types/ \
    -H 'Content-Type: application/json' \
    --data '{"name":"E2E Upgrade Type"}' | jq -r '.id')
  CUSTOM_FIELD_ID=$(api_request POST /api/custom_fields/ \
    -H 'Content-Type: application/json' \
    --data '{"name":"E2E Upgrade Field","data_type":"string","extra_data":{}}' | jq -r '.id')

  for id in "$TAG_ID" "$CORRESPONDENT_ID" "$DOCUMENT_TYPE_ID" "$CUSTOM_FIELD_ID"; do
    [[ "$id" =~ ^[0-9]+$ ]]
  done

  if [[ "$MODE" == "upgrade" ]]; then
    saved_view_query='note:E2E AND custom_field:E2E'
  else
    saved_view_query=$EXPECTED_SAVED_VIEW_QUERY
  fi
  saved_view_response=$(api_request POST /api/saved_views/ \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg query "$saved_view_query" '{name:"E2E Upgrade View",show_on_dashboard:true,show_in_sidebar:true,sort_field:"created",filter_rules:[{rule_type:20,value:$query}]}')")
  SAVED_VIEW_ID=$(jq -r '.id // empty' <<<"$saved_view_response")
  [[ "$SAVED_VIEW_ID" =~ ^[0-9]+$ ]]

  upload_response=$(api_request POST /api/documents/post_document/ \
    -F "document=@${fixture};type=application/pdf" \
    -F 'title=E2E Upgrade Document' \
    -F "correspondent=${CORRESPONDENT_ID}" \
    -F "document_type=${DOCUMENT_TYPE_ID}" \
    -F "tags=${TAG_ID}" \
    -F "custom_fields={\"${CUSTOM_FIELD_ID}\":\"E2E custom value\"}")
  [[ -n "$upload_response" ]]

  wait_for_document
  api_request POST "/api/documents/${DOCUMENT_ID}/notes/" \
    -H 'Content-Type: application/json' \
    --data '{"note":"E2E upgrade note"}' \
    | jq -e 'map(select(.note == "E2E upgrade note")) | length == 1' >/dev/null

  api_request GET "/api/documents/${DOCUMENT_ID}/download/" \
    --output /tmp/paperless-e2e-before.pdf
  ORIGINAL_DOCUMENT_HASH=$(sha256_file /tmp/paperless-e2e-before.pdf)
  [[ "$ORIGINAL_DOCUMENT_HASH" =~ ^[0-9a-f]{64}$ ]]
}

assert_named_object() {
  local endpoint=$1
  local name=$2
  api_request GET "/api/${endpoint}/?page_size=100" \
    | json_results \
    | jq -e --arg name "$name" 'map(select(.name == $name)) | length == 1' >/dev/null
}

verify_data() {
  local document
  local after_hash
  local saved_view

  assert_named_object tags "E2E Upgrade Tag"
  assert_named_object correspondents "E2E Upgrade Correspondent"
  assert_named_object document_types "E2E Upgrade Type"
  assert_named_object custom_fields "E2E Upgrade Field"
  assert_named_object saved_views "E2E Upgrade View"

  saved_view=$(api_request GET "/api/saved_views/${SAVED_VIEW_ID}/")
  jq -e --arg query "$EXPECTED_SAVED_VIEW_QUERY" '
    .filter_rules
    | length == 1
      and .[0].rule_type == 20
      and .[0].value == $query
  ' <<<"$saved_view" >/dev/null

  document=$(api_request GET "/api/documents/${DOCUMENT_ID}/")
  jq -e --argjson tag "$TAG_ID" --argjson correspondent "$CORRESPONDENT_ID" \
    --argjson document_type "$DOCUMENT_TYPE_ID" --argjson custom_field "$CUSTOM_FIELD_ID" '
      .title == "E2E Upgrade Document"
      and .correspondent == $correspondent
      and .document_type == $document_type
      and (.tags | index($tag) != null)
      and (
        .custom_fields
        | map(select(.field == $custom_field and .value == "E2E custom value"))
        | length == 1
      )
    ' <<<"$document" >/dev/null

  api_request GET "/api/documents/${DOCUMENT_ID}/notes/" \
    | jq -e 'map(select(.note == "E2E upgrade note")) | length == 1' >/dev/null

  api_request GET "/api/documents/${DOCUMENT_ID}/download/" \
    --output /tmp/paperless-e2e-after.pdf
  after_hash=$(sha256_file /tmp/paperless-e2e-after.pdf)
  [[ "$after_hash" == "$ORIGINAL_DOCUMENT_HASH" ]]

  wait_for_search_query E2E
  wait_for_search_query 'notes.note:E2E'
  wait_for_search_query 'custom_fields.value:E2E'
}

wait_for_search_query() {
  local query=$1
  local attempt
  local search_response

  for attempt in $(seq 1 120); do
    search_response=$(api_request GET '/api/documents/?page_size=100' \
      --get \
      --data-urlencode "query=${query}")
    if jq -e --argjson id "$DOCUMENT_ID" '
      (if type == "array" then . else (.results // []) end)
      | map(.id)
      | index($id) != null
    ' <<<"$search_response" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "Tantivy search did not return document ${DOCUMENT_ID} for query: ${query}" >&2
  return 1
}

verify_runtime_versions() {
  local postgres_pod
  local valkey_pod
  local postgres_version
  local valkey_version

  postgres_pod=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')
  valkey_pod=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=valkey \
    -o jsonpath='{.items[0].metadata.name}')

  postgres_version=$(kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless psql -U paperless -d paperless -Atc 'show server_version')
  [[ "$postgres_version" == 17.6* ]]

  valkey_version=$(kube exec -n "$NAMESPACE" "$valkey_pod" -- valkey-server --version)
  [[ "$valkey_version" == *"v=9.0.2"* ]]
}

backup_and_restore_rehearsal() {
  local postgres_pod
  local dump_file=/tmp/paperless-e2e-postgresql.sql
  local restored_documents

  postgres_pod=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')

  kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless \
    pg_dump -U paperless -d paperless --no-owner --no-privileges >"$dump_file"
  [[ -s "$dump_file" ]]
  sha256_file "$dump_file" | grep -Eq '^[0-9a-f]{64}$'

  kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless dropdb -U paperless --if-exists paperless_restore_e2e
  kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless createdb -U paperless paperless_restore_e2e
  kube exec -i -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless psql -U paperless -d paperless_restore_e2e \
    <"$dump_file" >/tmp/paperless-e2e-restore.log

  restored_documents=$(kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless psql -U paperless -d paperless_restore_e2e -Atc \
    'select count(*) from documents_document')
  [[ "$restored_documents" -ge 1 ]]

  kube exec -n "$NAMESPACE" "$postgres_pod" -- \
    env PGPASSWORD=paperless dropdb -U paperless paperless_restore_e2e
}

verify_paperless3_status() {
  local attempt
  local status
  API_ACCEPT='application/json; version=10'
  for attempt in $(seq 1 120); do
    status=$(api_request GET /api/status/)
    if jq -e --arg version "$EXPECTED_PAPERLESS_VERSION" '
      .pngx_version == $version
      and .database.status == "OK"
      and (.database.migration_status.unapplied_migrations | length == 0)
      and .tasks.redis_status == "OK"
      and .tasks.celery_status == "OK"
      and .tasks.index_status == "OK"
      and .tasks.summary.pending_count == 0
      and .tasks.summary.failure_count == 0
    ' <<<"$status" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  jq '{pngx_version,database,tasks:{redis_status:.tasks.redis_status,celery_status:.tasks.celery_status,index_status:.tasks.index_status,summary:.tasks.summary}}' \
    <<<"$status" >&2
  echo "Paperless 3 status did not become healthy" >&2
  return 1
}

install_candidate() {
  "$HELM_BIN" upgrade --install "$RELEASE" "$CANDIDATE_CHART" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --reset-values \
    --wait \
    --timeout 30m \
    "${common_values[@]}"
}

install_upgrade_base() {
  if [[ -n "$BASE_CHART_PACKAGE" ]]; then
    "$BASE_HELM_BIN" upgrade --install "$RELEASE" "$BASE_CHART_PACKAGE" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      --wait \
      --timeout 20m \
      "${common_values[@]}"
  else
    "$BASE_HELM_BIN" repo add paperless-e2e-base "$BASE_CHART_REPOSITORY" --force-update
    "$BASE_HELM_BIN" repo update paperless-e2e-base
    "$BASE_HELM_BIN" upgrade --install "$RELEASE" paperless-e2e-base/paperless-ngx \
      --version "$BASE_CHART_VERSION" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      --wait \
      --timeout 20m \
      "${common_values[@]}"
  fi
}

run_helm_test() {
  "$HELM_BIN" test "$RELEASE" -n "$NAMESPACE" --logs --timeout 5m
}

if [[ "$MODE" == "fresh" ]]; then
  install_candidate
  wait_for_application
  API_ACCEPT='application/json; version=10'
  start_port_forward
  authenticate
  seed_data
  verify_data
  verify_paperless3_status
  verify_runtime_versions
  run_helm_test
else
  install_upgrade_base
  wait_for_application
  start_port_forward
  authenticate
  seed_data
  backup_and_restore_rehearsal

  secret_before=$(kube get secret -n "$NAMESPACE" "$(app_deployment)" \
    -o jsonpath='{.data.PAPERLESS_SECRET_KEY}')
  [[ -n "$secret_before" ]]

  stop_port_forward
  deployment=$(app_deployment)
  kube scale deployment/"$deployment" -n "$NAMESPACE" --replicas=0
  kube rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=5m

  install_candidate
  wait_for_application
  API_ACCEPT='application/json; version=10'

  secret_after=$(kube get secret -n "$NAMESPACE" "$(app_deployment)" \
    -o jsonpath='{.data.PAPERLESS_SECRET_KEY}')
  [[ "$secret_after" == "$secret_before" ]]

  start_port_forward
  verify_data
  verify_paperless3_status
  verify_runtime_versions
  run_helm_test
fi

echo "Paperless ${MODE} E2E validation completed successfully"
