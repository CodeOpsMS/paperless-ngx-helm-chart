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
EXPECTED_KUBE_SERVER=${EXPECTED_KUBE_SERVER:-}
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
RUN_ID=${RUN_ID:-}
API_ACCEPT=application/json
PORT_FORWARD_PID=
API_TOKEN=
DOCUMENT_ID=
MATCHED_DOCUMENT_ID=
POST_UPGRADE_DOCUMENT_ID=
TAG_ID=
CORRESPONDENT_ID=
DOCUMENT_TYPE_ID=
CUSTOM_FIELD_ID=
SAVED_VIEW_ID=
ORIGINAL_DOCUMENT_HASH=
PVC_INVENTORY_BEFORE=
MOUNT_METADATA_BEFORE=
POSTGRES_PASSWORD_FINGERPRINT_BEFORE=
NAMESPACE_ACCEPTED=false
RESTORE_DATABASE_CREATED=false
RESTORE_POSTGRES_POD=
WORK_DIR=
NAMESPACE_OWNER_LABEL_KEY=e2e.paperless-ngx.codeopsms.de/owned
NAMESPACE_OWNER_ANNOTATION_KEY=e2e.paperless-ngx.codeopsms.de/release
EXPECTED_SAVED_VIEW_QUERY='notes.note:E2E AND custom_fields.value:E2E'
EXPECTED_PAPERLESS_VERSION=$(
  "$HELM_BIN" show chart "$CANDIDATE_CHART" \
    | awk '/^appVersion:/ { gsub(/"/, "", $2); print $2 }'
)
if ! [[ "$EXPECTED_PAPERLESS_VERSION" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
  echo "Candidate does not declare a stable Paperless 3 appVersion: ${EXPECTED_PAPERLESS_VERSION:-missing}" >&2
  exit 1
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="run-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
fi
if ! [[ "$RUN_ID" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
  echo "RUN_ID must match ^[a-z0-9][a-z0-9-]{0,31}$: ${RUN_ID}" >&2
  exit 1
fi

umask 077
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paperless-e2e.XXXXXXXX")
PORT_FORWARD_LOG=${WORK_DIR}/port-forward.log
FIXTURE_PATH=${WORK_DIR}/document.pdf
POST_UPGRADE_FIXTURE_PATH=${WORK_DIR}/post-upgrade-document.pdf
BEFORE_DOCUMENT_PATH=${WORK_DIR}/before.pdf
AFTER_DOCUMENT_PATH=${WORK_DIR}/after.pdf
POST_UPGRADE_DOWNLOAD_PATH=${WORK_DIR}/post-upgrade-download.pdf
DUMP_PATH=${WORK_DIR}/postgresql.sql
RESTORE_LOG_PATH=${WORK_DIR}/restore.log
UPGRADE_DOCUMENT_TITLE="E2E Upgrade Document ${RUN_ID}"
POST_UPGRADE_DOCUMENT_TITLE="E2E Post Upgrade Document ${RUN_ID}"
RESTORE_DATABASE="paperless_restore_${RUN_ID//-/_}"

common_values=(
  --set-string config.url=http://paperless.local
  --set-string env.PAPERLESS_TIME_ZONE=UTC
  --set env.PAPERLESS_CONSUMER_DELETE_DUPLICATES=true
  --set networkPolicy.enabled=true
  --set-string persistence.size=1Gi
  --set-string postgresql.primary.persistence.size=2Gi
)

kube() {
  if [[ -n "$KUBE_CONTEXT" && "$KUBE_INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
    "$KUBECTL_BIN" --context "$KUBE_CONTEXT" --insecure-skip-tls-verify=true "$@"
  elif [[ -n "$KUBE_CONTEXT" ]]; then
    "$KUBECTL_BIN" --context "$KUBE_CONTEXT" "$@"
  elif [[ "$KUBE_INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
    "$KUBECTL_BIN" --insecure-skip-tls-verify=true "$@"
  else
    "$KUBECTL_BIN" "$@"
  fi
}

helm_cluster() {
  local binary=$1
  shift
  if [[ -n "$KUBE_CONTEXT" && "$KUBE_INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
    "$binary" --kube-context "$KUBE_CONTEXT" --kube-insecure-skip-tls-verify "$@"
  elif [[ -n "$KUBE_CONTEXT" ]]; then
    "$binary" --kube-context "$KUBE_CONTEXT" "$@"
  elif [[ "$KUBE_INSECURE_SKIP_TLS_VERIFY" == "true" ]]; then
    "$binary" --kube-insecure-skip-tls-verify "$@"
  else
    "$binary" "$@"
  fi
}

postgresql_password_file() {
  local postgres_pod=$1
  local password_file

  password_file=$(kube get pod -n "$NAMESPACE" "$postgres_pod" -o json | jq -er '
    [
      .spec.containers[]
      | select(.name == "postgresql")
      | .env[]?
      | select(.name == "POSTGRES_PASSWORD_FILE")
      | .value
    ]
    | if length == 1 then .[0] else error("expected exactly one PostgreSQL password file") end
  ')
  case "$password_file" in
    /opt/bitnami/postgresql/secrets/*)
      printf '%s\n' "$password_file"
      ;;
    *)
      echo "Refusing unexpected PostgreSQL password file: ${password_file}" >&2
      return 1
      ;;
  esac
}

postgresql_password_fingerprint() {
  local postgres_pod=$1
  local password_file
  local fingerprint
  password_file=$(postgresql_password_file "$postgres_pod")
  fingerprint=$(kube exec -n "$NAMESPACE" "$postgres_pod" -- sha256sum "$password_file" | awk '{ print $1 }')
  if ! [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Could not fingerprint the mounted PostgreSQL password Secret" >&2
    return 1
  fi
  printf '%s\n' "$fingerprint"
}

postgres_exec() {
  local postgres_pod=$1
  local password_file
  shift
  password_file=$(postgresql_password_file "$postgres_pod")

  kube exec -n "$NAMESPACE" "$postgres_pod" -- sh -ceu '
    password_file=$1
    shift
    test -r "$password_file"
    PGPASSWORD=$(cat "$password_file")
    export PGPASSWORD
    exec "$@"
  ' sh "$password_file" "$@"
}

postgres_exec_stdin() {
  local postgres_pod=$1
  local password_file
  shift
  password_file=$(postgresql_password_file "$postgres_pod")

  kube exec -i -n "$NAMESPACE" "$postgres_pod" -- sh -ceu '
    password_file=$1
    shift
    test -r "$password_file"
    PGPASSWORD=$(cat "$password_file")
    export PGPASSWORD
    exec "$@"
  ' sh "$password_file" "$@"
}

verify_kube_server() {
  local actual_server
  if [[ -z "$EXPECTED_KUBE_SERVER" ]]; then
    return 0
  fi

  actual_server=$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  if [[ -z "$actual_server" ]]; then
    echo "Could not resolve the Kubernetes API server for the selected context" >&2
    return 1
  fi
  if [[ "${actual_server%/}" != "${EXPECTED_KUBE_SERVER%/}" ]]; then
    echo "Refusing Kubernetes server ${actual_server}; expected ${EXPECTED_KUBE_SERVER}" >&2
    return 1
  fi
  echo "Verified Kubernetes server: ${actual_server}"
}

namespace_is_owned() {
  local namespace_json
  namespace_json=$(kube get namespace "$NAMESPACE" -o json 2>/dev/null) || return 1
  jq -e \
    --arg label "$NAMESPACE_OWNER_LABEL_KEY" \
    --arg annotation "$NAMESPACE_OWNER_ANNOTATION_KEY" \
    --arg release "$RELEASE" \
    '(.metadata.labels[$label] // "") == "true"
      and (.metadata.annotations[$annotation] // "") == $release' \
    <<<"$namespace_json" >/dev/null
}

ensure_e2e_namespace() {
  verify_kube_server

  case "$NAMESPACE" in
    default|kube-system|kube-public|kube-node-lease)
      echo "Refusing to use protected Kubernetes namespace: $NAMESPACE" >&2
      return 1
      ;;
  esac

  if kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Refusing existing namespace ${NAMESPACE}; every E2E run must create a new namespace." >&2
    return 1
  fi

  kube create namespace "$NAMESPACE"
  kube label namespace "$NAMESPACE" "${NAMESPACE_OWNER_LABEL_KEY}=true" --overwrite
  kube annotate namespace "$NAMESPACE" "${NAMESPACE_OWNER_ANNOTATION_KEY}=${RELEASE}" --overwrite
  namespace_is_owned
  NAMESPACE_ACCEPTED=true
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

cleanup_restore_database() {
  if [[ "$RESTORE_DATABASE_CREATED" != "true" ]]; then
    return 0
  fi
  if [[ -z "$RESTORE_POSTGRES_POD" ]]; then
    echo "Cannot remove restore database ${RESTORE_DATABASE}: PostgreSQL pod is unknown" >&2
    return 1
  fi
  if ! namespace_is_owned; then
    echo "Cannot remove restore database ${RESTORE_DATABASE}: namespace ownership metadata changed" >&2
    return 1
  fi
  if ! postgres_exec "$RESTORE_POSTGRES_POD" \
    dropdb -U paperless --if-exists "$RESTORE_DATABASE"; then
    echo "Failed to remove restore database ${RESTORE_DATABASE}" >&2
    return 1
  fi
  RESTORE_DATABASE_CREATED=false
}

cleanup_work_dir() {
  local work_basename
  if [[ -z "$WORK_DIR" ]]; then
    return 0
  fi
  if [[ ! -e "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    return 0
  fi
  work_basename=${WORK_DIR##*/}
  case "$work_basename" in
    paperless-e2e.*)
      rm -rf -- "$WORK_DIR"
      ;;
    *)
      echo "Refusing to remove unexpected work directory: ${WORK_DIR}" >&2
      return 1
      ;;
  esac
}

finish() {
  local exit_code=$?
  local namespace_name
  trap - EXIT
  stop_port_forward
  if [[ $exit_code -ne 0 && "$NAMESPACE_ACCEPTED" == "true" ]]; then
    diagnostics
  fi
  if [[ "$RESTORE_DATABASE_CREATED" == "true" ]]; then
    if ! verify_kube_server; then
      echo "Skipping restore-database cleanup: the Kubernetes API server could not be verified." >&2
      exit_code=1
    elif ! cleanup_restore_database; then
      exit_code=1
    fi
  fi
  if [[ "$CLEANUP_NAMESPACE" == "true" && "$NAMESPACE_ACCEPTED" == "true" ]]; then
    if ! verify_kube_server; then
      echo "Skipping cleanup: the Kubernetes API server could not be verified." >&2
      exit_code=1
    elif namespace_is_owned; then
      if ! kube delete namespace "$NAMESPACE" --wait=true --timeout=40m; then
        echo "Failed to delete E2E namespace ${NAMESPACE}" >&2
        exit_code=1
      fi
    elif ! namespace_name=$(kube get namespace "$NAMESPACE" \
      --ignore-not-found -o name); then
      echo "Could not verify cleanup state for namespace ${NAMESPACE}" >&2
      exit_code=1
    elif [[ -n "$namespace_name" ]]; then
      echo "Skipping cleanup: namespace ${NAMESPACE} no longer has the expected E2E ownership metadata." >&2
      exit_code=1
    fi
  fi
  if ! cleanup_work_dir; then
    exit_code=1
  fi
  exit "$exit_code"
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
  kube rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=40m
  kube wait pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=paperless-ngx \
    --for=condition=Ready --timeout=40m
}

start_port_forward() {
  local service
  local attempt
  stop_port_forward
  service=$(app_service)
  kube port-forward -n "$NAMESPACE" service/"$service" "${LOCAL_PORT}:80" \
    >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID=$!
  for attempt in $(seq 1 120); do
    if curl --silent --output /dev/null --header 'Host: paperless.local' \
      "http://127.0.0.1:${LOCAL_PORT}/"; then
      return 0
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      cat "$PORT_FORWARD_LOG" >&2
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
  if [[ -n "$API_TOKEN" ]]; then
    curl --fail-with-body --silent --show-error \
      -X "$method" \
      -H 'Host: paperless.local' \
      -H "Accept: ${API_ACCEPT}" \
      -H "Authorization: Token ${API_TOKEN}" \
      "$@" \
      "http://127.0.0.1:${LOCAL_PORT}${path}"
  else
    curl --fail-with-body --silent --show-error \
      -X "$method" \
      -H 'Host: paperless.local' \
      -H "Accept: ${API_ACCEPT}" \
      "$@" \
      "http://127.0.0.1:${LOCAL_PORT}${path}"
  fi
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

extract_upload_task_id() {
  local response=$1
  jq -er '
    if type == "string"
      and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"; "i")
    then .
    else error("upload response is not a Celery UUID")
    end
  ' <<<"$response"
}

wait_for_upload_task_success() {
  local task_id=$1
  local attempt
  local response
  local task
  local task_status
  MATCHED_DOCUMENT_ID=

  for attempt in $(seq 1 180); do
    response=$(api_request GET "/api/tasks/?task_id=${task_id}")
    task=$(json_results <<<"$response" \
      | jq -c --arg task_id "$task_id" 'map(select(.task_id == $task_id)) | first // empty')
    if [[ -n "$task" ]]; then
      task_status=$(jq -r '(.status // "") | ascii_upcase' <<<"$task")
      case "$task_status" in
        SUCCESS)
          MATCHED_DOCUMENT_ID=$(jq -r '
            if ((.related_document_ids // []) | length) > 0 then
              .related_document_ids[0]
            elif .related_document != null then
              .related_document
            elif .result_data.document_id != null then
              .result_data.document_id
            else
              empty
            end
            | tostring
          ' <<<"$task")
          if [[ "$MATCHED_DOCUMENT_ID" =~ ^[0-9]+$ ]]; then
            return 0
          fi
          ;;
        FAILURE|REVOKED)
          echo "Paperless upload task ${task_id} ended with ${task_status}" >&2
          jq '{task_id,status,result,result_data}' <<<"$task" >&2
          return 1
          ;;
      esac
    fi
    sleep 2
  done
  echo "Paperless upload task ${task_id} did not finish successfully" >&2
  return 1
}

seed_data() {
  local upload_task_id
  local upload_response
  local saved_view_query
  local saved_view_response

  curl --fail --silent --show-error --location --retry 3 \
    https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v2.20.15/src/documents/tests/samples/simple.pdf \
    --output "$FIXTURE_PATH"
  [[ -s "$FIXTURE_PATH" ]]
  if [[ "$MODE" == "upgrade" ]]; then
    curl --fail --silent --show-error --location --retry 3 \
      https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v2.20.15/src/documents/tests/samples/double-sided-even.pdf \
      --output "$POST_UPGRADE_FIXTURE_PATH"
    [[ -s "$POST_UPGRADE_FIXTURE_PATH" ]]
  fi

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
    -F "document=@${FIXTURE_PATH};type=application/pdf" \
    -F "title=${UPGRADE_DOCUMENT_TITLE}" \
    -F "correspondent=${CORRESPONDENT_ID}" \
    -F "document_type=${DOCUMENT_TYPE_ID}" \
    -F "tags=${TAG_ID}" \
    -F "custom_fields={\"${CUSTOM_FIELD_ID}\":\"E2E custom value\"}")
  upload_task_id=$(extract_upload_task_id "$upload_response")

  wait_for_upload_task_success "$upload_task_id"
  DOCUMENT_ID=$MATCHED_DOCUMENT_ID
  api_request GET "/api/documents/${DOCUMENT_ID}/" \
    | jq -e --arg title "$UPGRADE_DOCUMENT_TITLE" '.title == $title' >/dev/null
  api_request POST "/api/documents/${DOCUMENT_ID}/notes/" \
    -H 'Content-Type: application/json' \
    --data '{"note":"E2E upgrade note"}' \
    | jq -e 'map(select(.note == "E2E upgrade note")) | length == 1' >/dev/null

  api_request GET "/api/documents/${DOCUMENT_ID}/download/?original=true" \
    --output "$BEFORE_DOCUMENT_PATH"
  ORIGINAL_DOCUMENT_HASH=$(sha256_file "$BEFORE_DOCUMENT_PATH")
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
  jq -e --arg title "$UPGRADE_DOCUMENT_TITLE" \
    --argjson tag "$TAG_ID" --argjson correspondent "$CORRESPONDENT_ID" \
    --argjson document_type "$DOCUMENT_TYPE_ID" --argjson custom_field "$CUSTOM_FIELD_ID" '
      .title == $title
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

  api_request GET "/api/documents/${DOCUMENT_ID}/download/?original=true" \
    --output "$AFTER_DOCUMENT_PATH"
  after_hash=$(sha256_file "$AFTER_DOCUMENT_PATH")
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

wait_for_task_queue_idle() {
  local attempt
  local tasks

  for attempt in $(seq 1 120); do
    tasks=$(api_request GET '/api/tasks/?page_size=100')
    if jq -e '
      (if type == "array" then . else (.results // []) end)
      | map(
          .status // ""
          | ascii_upcase
          | select(. == "PENDING" or . == "RECEIVED" or . == "STARTED" or . == "RETRY")
        )
      | length == 0
    ' <<<"$tasks" >/dev/null; then
      return 0
    fi
    sleep 5
  done

  jq '
    (if type == "array" then . else (.results // []) end)
    | map(select(((.status // "") | ascii_upcase) == "PENDING"
        or ((.status // "") | ascii_upcase) == "RECEIVED"
        or ((.status // "") | ascii_upcase) == "STARTED"
        or ((.status // "") | ascii_upcase) == "RETRY"))
    | map({id,status,task_name,date_created,date_done})
  ' <<<"$tasks" >&2
  echo "Paperless task queue did not drain before shutdown" >&2
  return 1
}

consume_post_upgrade_document() {
  local fixture_hash
  local downloaded_hash
  local upload_task_id
  local upload_response
  local document

  [[ -s "$POST_UPGRADE_FIXTURE_PATH" ]]
  fixture_hash=$(sha256_file "$POST_UPGRADE_FIXTURE_PATH")

  upload_response=$(api_request POST /api/documents/post_document/ \
    -F "document=@${POST_UPGRADE_FIXTURE_PATH};type=application/pdf" \
    -F "title=${POST_UPGRADE_DOCUMENT_TITLE}")
  upload_task_id=$(extract_upload_task_id "$upload_response")

  wait_for_upload_task_success "$upload_task_id"
  POST_UPGRADE_DOCUMENT_ID=$MATCHED_DOCUMENT_ID
  [[ "$POST_UPGRADE_DOCUMENT_ID" =~ ^[0-9]+$ ]]

  document=$(api_request GET "/api/documents/${POST_UPGRADE_DOCUMENT_ID}/")
  jq -e --arg title "$POST_UPGRADE_DOCUMENT_TITLE" \
    '.title == $title' <<<"$document" >/dev/null

  api_request GET "/api/documents/${POST_UPGRADE_DOCUMENT_ID}/download/?original=true" \
    --output "$POST_UPGRADE_DOWNLOAD_PATH"
  downloaded_hash=$(sha256_file "$POST_UPGRADE_DOWNLOAD_PATH")
  [[ "$downloaded_hash" == "$fixture_hash" ]]
}

pvc_inventory() {
  kube get pvc -n "$NAMESPACE" -o json \
    | jq -r '.items | sort_by(.metadata.name)[] | "\(.metadata.name)=\(.metadata.uid)"'
}

mount_metadata() {
  local pod
  pod=$(app_pod)
  kube exec -n "$NAMESPACE" "$pod" -- python3 -c '
import os
import stat

paths = (
    "/usr/src/paperless/data",
    "/usr/src/paperless/media",
    "/usr/src/paperless/consume",
    "/usr/src/paperless/export",
)
for path in paths:
    metadata = os.stat(path)
    mode = format(stat.S_IMODE(metadata.st_mode), "04o")
    print(f"{path}={metadata.st_uid}:{metadata.st_gid}:{mode}")
'
}

capture_storage_state() {
  PVC_INVENTORY_BEFORE=$(pvc_inventory)
  MOUNT_METADATA_BEFORE=$(mount_metadata)
  if [[ -z "$PVC_INVENTORY_BEFORE" ]]; then
    echo "No persistent volume claims were found before the upgrade" >&2
    return 1
  fi
  if [[ $(printf '%s\n' "$MOUNT_METADATA_BEFORE" | wc -l | tr -d ' ') -ne 4 ]]; then
    echo "Could not capture all Paperless mount ownership and modes" >&2
    return 1
  fi
  echo "PVC inventory before upgrade:"
  printf '%s\n' "$PVC_INVENTORY_BEFORE"
  echo "Paperless mount metadata before upgrade:"
  printf '%s\n' "$MOUNT_METADATA_BEFORE"
}

verify_storage_state() {
  local pvc_inventory_after
  local mount_metadata_after
  pvc_inventory_after=$(pvc_inventory)
  mount_metadata_after=$(mount_metadata)

  if [[ "$pvc_inventory_after" != "$PVC_INVENTORY_BEFORE" ]]; then
    echo "PVC names or UIDs changed during the upgrade" >&2
    echo "Before:" >&2
    printf '%s\n' "$PVC_INVENTORY_BEFORE" >&2
    echo "After:" >&2
    printf '%s\n' "$pvc_inventory_after" >&2
    return 1
  fi
  if [[ "$mount_metadata_after" != "$MOUNT_METADATA_BEFORE" ]]; then
    echo "Paperless mount ownership or modes changed during the upgrade" >&2
    echo "Before:" >&2
    printf '%s\n' "$MOUNT_METADATA_BEFORE" >&2
    echo "After:" >&2
    printf '%s\n' "$mount_metadata_after" >&2
    return 1
  fi
  echo "PVC names, UIDs, mount ownership, and mount modes were preserved"
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

  postgres_version=$(postgres_exec "$postgres_pod" \
    psql -U paperless -d paperless -Atc 'show server_version')
  [[ "$postgres_version" == 17.6* ]]

  valkey_version=$(kube exec -n "$NAMESPACE" "$valkey_pod" -- valkey-server --version)
  [[ "$valkey_version" == *"v=9.0.5"* ]]
}

database_inventory() {
  local postgres_pod=$1
  local database=$2
  postgres_exec "$postgres_pod" \
    psql -X --set=ON_ERROR_STOP=1 -At -F '=' -U paperless -d "$database" -c "
      select relation_name, row_count
      from (
        select 'auth_user' as relation_name, count(*)::bigint as row_count from auth_user
        union all select 'documents_correspondent', count(*)::bigint from documents_correspondent
        union all select 'documents_customfield', count(*)::bigint from documents_customfield
        union all select 'documents_document', count(*)::bigint from documents_document
        union all select 'documents_documenttype', count(*)::bigint from documents_documenttype
        union all select 'documents_savedview', count(*)::bigint from documents_savedview
        union all select 'documents_tag', count(*)::bigint from documents_tag
      ) as inventory
      order by relation_name
    "
}

backup_and_restore_rehearsal() {
  local postgres_pod
  local source_inventory
  local restored_inventory

  postgres_pod=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')
  RESTORE_POSTGRES_POD=$postgres_pod

  source_inventory=$(database_inventory "$postgres_pod" paperless)
  if [[ $(printf '%s\n' "$source_inventory" | wc -l | tr -d ' ') -ne 7 ]]; then
    echo "Could not capture the complete source database inventory" >&2
    return 1
  fi

  postgres_exec "$postgres_pod" \
    pg_dump -U paperless -d paperless --no-owner --no-privileges >"$DUMP_PATH"
  [[ -s "$DUMP_PATH" ]]
  sha256_file "$DUMP_PATH" | grep -Eq '^[0-9a-f]{64}$'

  postgres_exec "$postgres_pod" \
    createdb -U paperless -T template0 "$RESTORE_DATABASE"
  RESTORE_DATABASE_CREATED=true
  postgres_exec_stdin "$postgres_pod" \
    psql -X --set=ON_ERROR_STOP=1 --single-transaction \
    -U paperless -d "$RESTORE_DATABASE" \
    <"$DUMP_PATH" >"$RESTORE_LOG_PATH"

  restored_inventory=$(database_inventory "$postgres_pod" "$RESTORE_DATABASE")
  if [[ "$restored_inventory" != "$source_inventory" ]]; then
    echo "Restored PostgreSQL inventory does not match the source database" >&2
    echo "Source:" >&2
    printf '%s\n' "$source_inventory" >&2
    echo "Restored:" >&2
    printf '%s\n' "$restored_inventory" >&2
    return 1
  fi
  echo "PostgreSQL restore inventory verified:"
  printf '%s\n' "$restored_inventory"

  postgres_exec "$postgres_pod" dropdb -U paperless "$RESTORE_DATABASE"
  RESTORE_DATABASE_CREATED=false
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
  helm_cluster "$HELM_BIN" upgrade --install "$RELEASE" "$CANDIDATE_CHART" \
    --namespace "$NAMESPACE" \
    --reset-values \
    --wait \
    --timeout 40m \
    "${common_values[@]}"
}

install_upgrade_base() {
  if [[ -n "$BASE_CHART_PACKAGE" ]]; then
    helm_cluster "$BASE_HELM_BIN" upgrade --install "$RELEASE" "$BASE_CHART_PACKAGE" \
      --namespace "$NAMESPACE" \
      --wait \
      --timeout 40m \
      "${common_values[@]}"
  else
    "$BASE_HELM_BIN" repo add paperless-e2e-base "$BASE_CHART_REPOSITORY" --force-update
    "$BASE_HELM_BIN" repo update paperless-e2e-base
    helm_cluster "$BASE_HELM_BIN" upgrade --install "$RELEASE" paperless-e2e-base/paperless-ngx \
      --version "$BASE_CHART_VERSION" \
      --namespace "$NAMESPACE" \
      --wait \
      --timeout 40m \
      "${common_values[@]}"
  fi
}

run_helm_test() {
  helm_cluster "$HELM_BIN" test "$RELEASE" -n "$NAMESPACE" --logs --timeout 5m
}

echo "E2E run ID: ${RUN_ID}"
ensure_e2e_namespace

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
  wait_for_task_queue_idle
  backup_and_restore_rehearsal
  capture_storage_state

  postgres_pod_before=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')
  POSTGRES_PASSWORD_FINGERPRINT_BEFORE=$(postgresql_password_fingerprint "$postgres_pod_before")

  secret_before=$(kube get secret -n "$NAMESPACE" "$(app_deployment)" \
    -o jsonpath='{.data.PAPERLESS_SECRET_KEY}')
  [[ -n "$secret_before" ]]

  wait_for_task_queue_idle
  stop_port_forward
  deployment=$(app_deployment)
  kube scale deployment/"$deployment" -n "$NAMESPACE" --replicas=0
  kube rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=40m

  install_candidate
  wait_for_application
  API_ACCEPT='application/json; version=10'

  secret_after=$(kube get secret -n "$NAMESPACE" "$(app_deployment)" \
    -o jsonpath='{.data.PAPERLESS_SECRET_KEY}')
  [[ "$secret_after" == "$secret_before" ]]
  postgres_pod_after=$(kube get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/instance="$RELEASE",app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')
  postgres_password_fingerprint_after=$(postgresql_password_fingerprint "$postgres_pod_after")
  if [[ "$postgres_password_fingerprint_after" != "$POSTGRES_PASSWORD_FINGERPRINT_BEFORE" ]]; then
    echo "Bundled PostgreSQL user password changed during the chart upgrade" >&2
    exit 1
  fi
  verify_storage_state

  start_port_forward
  verify_data
  consume_post_upgrade_document
  verify_paperless3_status
  verify_runtime_versions
  run_helm_test
fi

echo "Paperless ${MODE} E2E validation completed successfully"
