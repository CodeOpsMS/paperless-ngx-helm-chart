# Maintainer acceptance testing

The pull-request workflow uploads the exact packaged candidate as the immutable,
attempt-specific artifact
`paperless-ngx-candidate-<run-id>-<run-attempt>`. Kind validates that candidate
on Kubernetes 1.34-1.36. Before releasing 0.4.0, the same artifact must pass the
real-cluster acceptance test in the isolated `suseai` namespace.

## Verify dependency discovery locally

Before starting a cluster test, verify that the generated Paperless Secret
targets the Services rendered by the PostgreSQL and Valkey dependencies. The
check covers default values, dependency overrides, PostgreSQL replication, and
a maximum-length Helm release name:

```bash
helm dependency build .
scripts/verify-chart-dependencies.sh
helm lint --strict .
helm unittest --strict .
scripts/verify-internal-service-names.sh
```

CI builds the package twice and canonicalizes both archives with
`scripts/normalize-chart-package.py`; their bytes must compare equal before the
attempt-specific candidate is uploaded. A regression test rejects unsafe archive
paths and entry types and verifies canonical ordering, metadata, and file modes.
This removes Helm's nondeterministic ordering of expanded dependency files while
retaining the exact tested bytes.

Run the same commands with both supported Helm lines. In CI this check is part
of each Helm 3.21.x and Helm 4.2.x static job.

## Download the candidate

Identify the successful Helm CI run for the upgrade PR and download its
candidate without rebuilding it locally:

```bash
gh run list --workflow helm-ci.yml --branch chore/update-paperless-ngx-3.0.5
gh run download <run-id> --name paperless-ngx-candidate-<run-id>-<run-attempt> \
  --dir /tmp/paperless-ngx-0.4.0-candidate
```

Record the SHA-256 hash of the downloaded package in the PR acceptance comment.

## Authenticate to Rancher

Refresh the local Rancher/Kubernetes credentials before testing. The preflight
must return `yes` with normal certificate verification; `system:unauthenticated`
or a TLS error is a hard blocker:

```bash
EXPECTED_KUBE_SERVER=https://rancherai.laemmerzahl.de/k8s/clusters/c-gf4m7
ACTUAL_KUBE_SERVER=$(kubectl --context suseai config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')
test "${ACTUAL_KUBE_SERVER%/}" = "${EXPECTED_KUBE_SERVER%/}"
kubectl --context suseai auth can-i create namespaces
```

Install the Rancher/private CA in the kubeconfig or local trust store when TLS
verification fails. `KUBE_INSECURE_SKIP_TLS_VERIFY=true` is available only as a
temporary troubleshooting override for both kubectl and Helm. A run performed
with that override is not release acceptance evidence and must be repeated with
certificate verification enabled.

## Run the isolated upgrade test

The runner installs chart 0.3.23/Paperless 2.20.15, creates only synthetic
objects and upstream test-fixture PDFs, rehearses a PostgreSQL logical restore,
scales the application to zero, upgrades the exact candidate, and verifies
Paperless 3, PostgreSQL 17.6, Valkey 9.0.5, Tantivy search, API v10, Secret
preservation, PVC names and UIDs, mount ownership and modes, and file hashes.
It drains the Paperless 2 task queue before shutdown and proves that a new
document can be consumed after the upgrade. NetworkPolicy is enabled throughout
the run, and the restore rehearsal compares exact row-count signatures for the
core users, documents, and classification metadata. Database commands read the
password only from the Secret file mounted in the PostgreSQL pod, and the test
compares password fingerprints before and after the upgrade without printing
the credential.

Unit and render tests also assert that no Deployment annotation is derived from
database, broker, OIDC, or arbitrary environment Secret values. Rollouts for
that Secret-backed configuration use the explicit, non-sensitive
`config.secretRevision`.

The script is compatible with the macOS system Bash 3.2 as well as current
Bash releases. It requires `curl`, `jq`, `kubectl`, and Helm. The selected Helm
and kubectl invocations are both pinned to `KUBE_CONTEXT`. It creates a unique
cryptographically random `RUN_ID`; record the printed value with the evidence.

```bash
KUBECTL_BIN=/opt/homebrew/bin/kubectl \
HELM_BIN=/opt/homebrew/bin/helm \
BASE_HELM_BIN=/opt/homebrew/bin/helm \
KUBE_CONTEXT=suseai \
EXPECTED_KUBE_SERVER=https://rancherai.laemmerzahl.de/k8s/clusters/c-gf4m7 \
NAMESPACE=paperless-ngx-v3-e2e \
RELEASE=paperless-v3-e2e \
CLEANUP_NAMESPACE=false \
scripts/paperless-e2e.sh upgrade \
  /tmp/paperless-ngx-0.4.0-candidate/paperless-ngx-0.4.0.tgz
```

Use a new, dedicated namespace and never point the runner at a production
release. The runner creates the namespace itself and records both an ownership
label and the expected release annotation. It rejects every existing namespace,
including a marked or empty one, because custom Kubernetes resources cannot be
proven absent from a fixed resource list. Use a new namespace after every
completed or interrupted E2E run.
`CLEANUP_NAMESPACE=true` can delete only a namespace whose ownership metadata
still matches; otherwise cleanup fails the run without deleting it.

The automated owner/mode comparison is deliberately read-only. The API upload
proves that Paperless can write its data and media paths, but the runner does
not create probe files in `consume` or `export`; validate special ACL, SELinux,
or non-root configurations separately when those paths differ from the tested
defaults.

## Evidence and cleanup

Attach the following to PR #7:

- candidate package SHA-256;
- generated E2E `RUN_ID` and verified Kubernetes API server;
- Helm and Kubernetes versions;
- successful script output;
- Paperless `/api/status/` result with sensitive URLs removed;
- PostgreSQL and Valkey version output;
- unchanged bundled PostgreSQL password fingerprint;
- preserved PVC name/UID inventory and Paperless mount owner/mode inventory;
- successful consumption and hash verification of the post-upgrade document;
- successful `helm test` result;
- confirmation that only synthetic data was used.

After evidence is captured, remove the namespace:

```bash
set -euo pipefail
context=suseai
namespace=paperless-ngx-v3-e2e
release=paperless-v3-e2e
expected_server=https://rancherai.laemmerzahl.de/k8s/clusters/c-gf4m7

actual_server=$(kubectl --context "$context" config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')
test "${actual_server%/}" = "${expected_server%/}"

namespace_json=$(kubectl --context "$context" get namespace "$namespace" -o json)
owner=$(jq -er --arg key 'e2e.paperless-ngx.codeopsms.de/owned' \
  '.metadata.labels[$key] // empty' <<<"$namespace_json")
marked_release=$(jq -er --arg key 'e2e.paperless-ngx.codeopsms.de/release' \
  '.metadata.annotations[$key] // empty' <<<"$namespace_json")
test "$owner" = true
test "$marked_release" = "$release"

kubectl --context "$context" delete namespace "$namespace" \
  --wait=true --timeout=40m
```

Every check above must succeed before Bash reaches the deletion. Alternatively,
repeat the test in a new namespace with `CLEANUP_NAMESPACE=true` after all
evidence has been retained.
