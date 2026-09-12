# Maintainer acceptance testing

The pull-request workflow uploads the exact packaged candidate as the immutable,
attempt-specific artifact
`paperless-ngx-candidate-<run-id>-<run-attempt>`. Kind validates that candidate
on Kubernetes 1.34-1.36. Before releasing `0.4.0`, the same
artifact must pass the protected real-cluster job against both baselines in
new, isolated test namespaces. See [CLUSTER-ACCEPTANCE.md](CLUSTER-ACCEPTANCE.md)
for the mandatory release dependency and one-time safe infrastructure setup.
The examples below are private, manual rehearsals; they do not bypass acceptance
of the exact main CI artifact by the publishing workflow.
This document describes required checks; it is not
evidence that the current candidate has passed them.

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
gh run list --workflow helm-ci.yml --branch codex/release-0.4.0
gh run download <run-id> --name paperless-ngx-candidate-<run-id>-<run-attempt> \
  --dir /tmp/paperless-ngx-0.4.0-candidate
```

Record the SHA-256 hash of the downloaded package in the PR acceptance comment.

## Select both upgrade baselines

Run both upgrade paths against that exact candidate:

| Baseline chart | Baseline Paperless | Purpose |
| --- | --- | --- |
| `0.3.23` | `2.20.15` | Validate the major-version database and search migration |
| `0.4.0-experimental.1` | `3.0.5` | Validate updates from an existing Paperless 3 preview |

`BASE_CHART_VERSION` selects the released chart from `BASE_CHART_REPOSITORY`
(the project's Helm repository by default). `BASE_CHART_PACKAGE` selects an
already downloaded baseline archive instead and takes precedence over the
repository download. Set `BASE_CHART_VERSION` to the matching version in either
case and retain the exact baseline bytes and hash as evidence. CI downloads the
released archives and checks these SHA-256 values before installing them:

| Baseline chart | Package SHA-256 |
| --- | --- |
| `0.3.23` | `6202d81c112d3e810d9abb37e16d5aa141a7b6a4e85911d4ff0c257f275beb22` |
| `0.4.0-experimental.1` | `fcd72197aeb88735f64ba571d65ff882999ada4507238ce86bc7ee5e952d72df` |

The Paperless 2 baseline seeds a Whoosh saved query using
`note:E2E AND custom_field:E2E`; the candidate must migrate it to
`notes.note:E2E AND custom_fields.value:E2E`. The Paperless 3 baseline already
uses that Tantivy query and API v10 before the upgrade. The runner determines
this from the installed baseline's declared application version, rather than
treating every upgrade as a Paperless 2 migration.

## Authenticate to Rancher

Locate or refresh the actual local Rancher/Kubernetes credentials before
testing. If they are outside the default kubeconfig location, export
`KUBECONFIG` with the verified file path so both Helm and kubectl use it. Do not
assume that a kubeconfig mentioned in an earlier run still exists. The preflight
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

## Run the isolated upgrade tests

### Check whether the production topology matches the test

The runner validates the bundled PostgreSQL/Valkey topology with synthetic
data and newly provisioned storage. A successful run on a production cluster
does **not** validate every integration used by its existing Paperless release.
Before planning a production upgrade, inventory all workloads that access the
same database, broker, and media/search storage, including separate web-only
Deployments, workers, CronJobs, and independently managed Fleet/GitOps releases.
The main chart cannot stop or update workloads owned by another release.

For split deployments, suspend the relevant reconciliation and autoscaling,
drain tasks, and stop **all** old application processes before applying the v3
migrations. Update every component to the same reviewed Paperless version
before resuming it. Scaling down only the main chart's Deployment is
insufficient when another web release still uses the same database and index.
Do not suspend or modify production controllers as part of this isolated test.

Preserve external database/Sentinel configuration, custom Django settings
modules, existing Secret references, and the existing NFS/RWX claim where
present; do not accidentally enable bundled backends or allocate replacement
application storage. Rehearse that topology separately on restored, isolated
data. A custom settings module may override Paperless 3 broker/serializer or
cache defaults and requires its own source-level review. Record the actual
StorageClass selected for test PVCs, especially when a cluster has multiple
default StorageClasses; CSI/RWO test volumes do not prove NFS/RWX behavior.

### Execute each baseline

For each selected baseline, the runner creates only synthetic
objects and upstream test-fixture PDFs, rehearses a PostgreSQL logical restore,
scales the application to zero, upgrades the exact candidate, and verifies
the candidate Paperless version, PostgreSQL 17.6, Valkey 9.0.5, Tantivy search,
API v10, Secret preservation, PVC names and UIDs, mount ownership and modes,
file hashes, and a
zero-surge, fully unavailable rollout with exactly one migration pod and no
HPA. It also waits for every Deployment-owned baseline Paperless pod to be
deleted before installing the Paperless 3 candidate.
It observes three consecutive idle snapshots of all configured Redis priority
queues, unacknowledged deliveries and all expected workers' active/reserved/
scheduled tasks before shutdown, failing closed on missing replies. It proves that a new
document can be consumed after the upgrade. NetworkPolicy is enabled throughout
the run, and the restore rehearsal compares exact row-count signatures for the
core users, documents, and classification metadata. Database commands read the
password only from the Secret file mounted in the PostgreSQL pod, and the test
compares password fingerprints before and after the upgrade without printing
the credential.

The candidate starts with `PAPERLESS_SEARCH_LANGUAGE=de`, exercising the
upstream fix for explicit search-language configuration. It also verifies live
Flower metrics through both Service and Pod IP from a separate pod. With
`MONITORING_E2E=true`, preinstalled monitoring CRDs/operator must reconcile the
chart's ServiceMonitor and PrometheusRule into successful actual scrapes,
stored Flower samples and a firing test alert. With
`REQUIRE_NETWORK_POLICY_ENFORCEMENT=true`, a non-allowed probe must be blocked.
Both flags are mandatory in the real-cluster release job and the dedicated
Cilium-backed Kind monitoring job. The other Kind jobs retain their basic CNI;
NetworkPolicy presence alone there is not evidence of enforcement. Remote OCR mode
compatibility is covered by schema/render tests; this acceptance run does not
send documents to an external OCR or AI provider.

The runner supplies explicit PostgreSQL and Valkey pod selectors to the exact
0.3.23 package. This preserves active network isolation while avoiding that
historical release's broken generated-egress fallback; the baseline archive is
neither patched nor rebuilt. Current-chart default discovery remains covered by
the dedicated render and unit tests.

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
BASE_CHART_VERSION=0.3.23 \
KUBE_CONTEXT=suseai \
EXPECTED_KUBE_SERVER=https://rancherai.laemmerzahl.de/k8s/clusters/c-gf4m7 \
NAMESPACE=paperless-v2-to-v313-e2e \
RELEASE=paperless-v3-e2e \
CLEANUP_NAMESPACE=false \
scripts/paperless-e2e.sh upgrade \
  /tmp/paperless-ngx-0.4.0-candidate/paperless-ngx-0.4.0.tgz
```

Repeat for the existing Paperless 3 preview in a different namespace. The
example uses a previously downloaded, checksum-verified baseline package:

```bash
KUBECTL_BIN=/opt/homebrew/bin/kubectl \
HELM_BIN=/opt/homebrew/bin/helm \
BASE_HELM_BIN=/opt/homebrew/bin/helm \
BASE_CHART_VERSION=0.4.0-experimental.1 \
BASE_CHART_PACKAGE=/tmp/paperless-ngx-baselines/paperless-ngx-0.4.0-experimental.1.tgz \
KUBE_CONTEXT=suseai \
EXPECTED_KUBE_SERVER=https://rancherai.laemmerzahl.de/k8s/clusters/c-gf4m7 \
NAMESPACE=paperless-v305-to-v313-e2e \
RELEASE=paperless-v3-e2e \
CLEANUP_NAMESPACE=false \
scripts/paperless-e2e.sh upgrade \
  /tmp/paperless-ngx-0.4.0-candidate/paperless-ngx-0.4.0.tgz
```

Omit `BASE_CHART_PACKAGE` to download the selected `BASE_CHART_VERSION` from
the Helm repository instead. `BASE_HELM_BIN` may differ from `HELM_BIN` to
exercise a Helm 3-to-4 upgrade. CI covers Helm 3-to-3, Helm 3-to-4, and Helm
4-to-4 for the 2.20.15 baseline, plus Helm 4-to-4 for the 3.0.5 baseline. Run
the two examples sequentially because they use the same local forwarding port.

Use a new, dedicated namespace and never point the runner at a production
release. The runner creates the namespace itself and records both an ownership
label and the expected release annotation. It rejects every existing namespace,
including a marked or empty one, because custom Kubernetes resources cannot be
proven absent from a fixed resource list. Use a new namespace after every
completed or interrupted E2E run.
`CLEANUP_NAMESPACE=true` can delete only a namespace whose ownership metadata
still matches; otherwise cleanup fails the run without deleting it.

The automated owner/mode comparison is read-only. In addition to the API upload,
each fresh-install and upgrade test writes a synthetic upstream PDF as user
`paperless` to an ignored `._`-prefixed file in `consume`, then atomically
renames it within that mount. Moving from `export` could cross Kubernetes
subPath bind mounts and fall back to a non-atomic copy. The runner waits for
directory ingestion and checks the downloaded original's SHA-256. This verifies
the default `consume`, `data`, and `media` write paths, not export creation.
Validate export permissions and special ACL, SELinux, or non-root configurations
separately when they differ from the tested defaults.

## Evidence and cleanup

Retain the following privately for each baseline, and attach a sanitized
summary to the release PR. Never publish cluster hostnames, credentials,
production resource inventories, or complete Helm values:

- candidate package SHA-256, baseline version, and baseline package SHA-256;
- generated E2E `RUN_ID` and verified Kubernetes API server;
- Helm and Kubernetes versions;
- successful script output;
- the runner's sanitized Paperless `/api/status/` summary, without credentials
  or service URLs;
- confirmed startup with explicit search language and a successful live Flower
  `/metrics` check;
- PostgreSQL and Valkey version output;
- unchanged bundled PostgreSQL password fingerprint;
- preserved PVC name/UID inventory and Paperless mount owner/mode inventory;
- successful API upload, atomic directory consumption, and original-file hash
  verification after the upgrade;
- successful `helm test` result;
- confirmation that only synthetic data was used.

If credentials, cluster access, or any test fails, record the failed preflight
or check and the remaining acceptance gap. A local render, an older candidate's
success, or a green Kind job does not establish a real-cluster result for this
candidate and both baselines.

After evidence is captured, remove the namespace:

```bash
set -euo pipefail
context=suseai
namespace=paperless-v2-to-v313-e2e
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
evidence has been retained. Repeat the same ownership-checked cleanup for the
second test namespace, substituting its exact name.
