#!/usr/bin/env bash
# Only the disposable GitHub-hosted Kind workflow may run this acceptance path.
set -euo pipefail
candidate=${1:?Candidate chart required}
[[ "${CI:-}" == true && "${GITHUB_JOB:-}" == kind-acceptance ]]
test "$(kubectl config current-context)" = kind-chart-testing
: "${GITHUB_OUTPUT:?GitHub output file required}"
: "${SOURCE_SHA:?Source commit required}"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
test -s "$candidate"
candidate_sha=$(sha256sum "$candidate" | awk '{print $1}')
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

for baseline in 0.3.23 0.4.0-experimental.1; do
  case "$baseline" in
    0.3.23) baseline_sha=6202d81c112d3e810d9abb37e16d5aa141a7b6a4e85911d4ff0c257f275beb22; suffix=v2 ;;
    *) baseline_sha=fcd72197aeb88735f64ba571d65ff882999ada4507238ce86bc7ee5e952d72df; suffix=v3 ;;
  esac
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/CodeOpsMS/paperless-ngx-helm-chart/releases/download/paperless-ngx-${baseline}/paperless-ngx-${baseline}.tgz" \
    --output "$work/baseline.tgz"
  test "$(sha256sum "$work/baseline.tgz" | awk '{print $1}')" = "$baseline_sha"
  KUBE_CONTEXT=kind-chart-testing KUBE_INSECURE_SKIP_TLS_VERIFY=false \
    NAMESPACE="paperless-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${suffix}" \
    RELEASE=paperless-e2e CLEANUP_NAMESPACE=true \
    BASE_CHART_VERSION="$baseline" BASE_CHART_PACKAGE="$work/baseline.tgz" \
    MONITORING_E2E=true REQUIRE_NETWORK_POLICY_ENFORCEMENT=true \
    scripts/paperless-e2e.sh upgrade "$candidate"
done

# Emit approval only after both tests, namespace cleanup and unchanged bytes.
test "$(sha256sum "$candidate" | awk '{print $1}')" = "$candidate_sha"
printf 'sha256=%s\nsource_sha=%s\n' "$candidate_sha" "$SOURCE_SHA" >>"$GITHUB_OUTPUT"
echo "Both GitHub Kind upgrades, monitoring, broker checks and cleanup passed: ${candidate_sha}"
