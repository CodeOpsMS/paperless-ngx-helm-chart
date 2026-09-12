#!/usr/bin/env bash
# Credentials and detailed cluster diagnostics must never reach public CI logs.
set -euo pipefail
umask 077
candidate=${1:?Candidate chart required}
: "${KUBECONFIG:?Dedicated test-cluster kubeconfig required}"
: "${KUBE_CONTEXT:?Explicit test context required}"
: "${EXPECTED_KUBE_SERVER:?Explicit test API server required}"
: "${E2E_STORAGE_CLASS:?Dedicated Delete-reclaim StorageClass required}"
: "${GITHUB_OUTPUT:?GitHub output file required}"
: "${SOURCE_SHA:?Source commit required}"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
[[ "${ACCEPTANCE_ENABLED:-}" == true ]]
[[ "${KUBE_INSECURE_SKIP_TLS_VERIFY:-false}" == false ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
candidate_sha=$(sha256sum "$candidate" | awk '{print $1}')
acceptance() {
  local settings server storage marker baseline baseline_sha suffix namespace
  settings=$(kubectl --context "$KUBE_CONTEXT" config view --minify -o json)
  server=$(jq -er '.clusters[0].cluster.server' <<<"$settings")
  [[ "$server" == https://* && "${server%/}" == "${EXPECTED_KUBE_SERVER%/}" ]]
  jq -e '(.clusters[0].cluster["insecure-skip-tls-verify"] // false) == false' <<<"$settings" >/dev/null
  kubectl --context "$KUBE_CONTEXT" --request-timeout=30s get --raw=/version >/dev/null
  marker=$(kubectl --context "$KUBE_CONTEXT" get configmap acceptance-target \
    -n paperless-acceptance-system -o jsonpath='{.data.purpose}')
  [[ "$marker" == paperless-isolated-release-tests ]]
  storage=$(kubectl --context "$KUBE_CONTEXT" get storageclass "$E2E_STORAGE_CLASS" -o json)
  jq -e '.reclaimPolicy == "Delete"' <<<"$storage" >/dev/null
  kubectl --context "$KUBE_CONTEXT" get crd servicemonitors.monitoring.coreos.com \
    prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com >/dev/null
  for baseline in 0.3.23 0.4.0-experimental.1; do
    case "$baseline" in
      0.3.23) baseline_sha=6202d81c112d3e810d9abb37e16d5aa141a7b6a4e85911d4ff0c257f275beb22; suffix=v2 ;;
      *) baseline_sha=fcd72197aeb88735f64ba571d65ff882999ada4507238ce86bc7ee5e952d72df; suffix=v3 ;;
    esac
    curl --fail --silent --show-error --location --retry 3 \
      "https://codeopsms.github.io/paperless-ngx-helm-chart/paperless-ngx-${baseline}.tgz" \
      --output "$work/baseline.tgz"
    test "$(sha256sum "$work/baseline.tgz" | awk '{print $1}')" = "$baseline_sha"
    namespace="paperless-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${suffix}-$(openssl rand -hex 4)"
    NAMESPACE="$namespace" RELEASE=paperless-e2e CLEANUP_NAMESPACE=true \
      BASE_CHART_VERSION="$baseline" BASE_CHART_PACKAGE="$work/baseline.tgz" \
      MONITORING_E2E=true REQUIRE_NETWORK_POLICY_ENFORCEMENT=true \
      scripts/paperless-e2e.sh upgrade "$candidate" || return 1
  done
  # Detect any unexpected change while testing. Success includes namespace cleanup.
  test "$(sha256sum "$candidate" | awk '{print $1}')" = "$candidate_sha"
}
# Run in a subshell so errexit remains active inside acceptance(). Do not put
# the function itself on the left side of `if`, which disables Bash errexit.
set +e
( set -e; acceptance ) >"$work/private.log" 2>&1
result=$?
set -e
if [[ "$result" -ne 0 ]]; then
  echo "::error::Isolated real-cluster acceptance failed. Detailed logs were withheld to protect cluster data. Reproduce privately using TESTING.md."
  exit "$result"
fi
printf 'sha256=%s\nsource_sha=%s\n' "$candidate_sha" "$SOURCE_SHA" >>"$GITHUB_OUTPUT"
echo "Both real-cluster upgrades, monitoring, broker checks and cleanup passed: ${candidate_sha}"
