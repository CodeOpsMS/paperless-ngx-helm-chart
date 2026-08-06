# Maintainer acceptance testing

The pull-request workflow uploads the exact packaged candidate as the artifact
`paperless-ngx-0.4.0-candidate`. Kind validates that candidate on Kubernetes
1.34-1.36. Before releasing 0.4.0, the same artifact must pass the real-cluster
acceptance test in the isolated `suseai` namespace.

## Verify dependency discovery locally

Before starting a cluster test, verify that the generated Paperless Secret
targets the Services rendered by the PostgreSQL and Valkey dependencies. The
check covers default values, dependency overrides, PostgreSQL replication, and
a maximum-length Helm release name:

```bash
helm dependency build .
helm lint --strict .
helm unittest --strict .
scripts/verify-internal-service-names.sh
```

Run the same commands with both supported Helm lines. In CI this check is part
of each Helm 3.21.x and Helm 4.2.x static job.

## Download the candidate

Identify the successful Helm CI run for the upgrade PR and download its
candidate without rebuilding it locally:

```bash
gh run list --workflow helm-ci.yml --branch chore/update-paperless-ngx-3.0.5
gh run download <run-id> --name paperless-ngx-0.4.0-candidate \
  --dir /tmp/paperless-ngx-0.4.0-candidate
```

Record the SHA-256 hash of the downloaded package in the PR acceptance comment.

## Authenticate to Rancher

Refresh the local Rancher/Kubernetes credentials before testing. The preflight
must return `yes`; `system:unauthenticated` is a hard blocker:

```bash
kubectl --context suseai --insecure-skip-tls-verify=true \
  auth can-i create namespaces
```

## Run the isolated upgrade test

The runner installs chart 0.3.23/Paperless 2.20.15, creates only synthetic
objects and a synthetic PDF, rehearses a PostgreSQL logical restore, scales the
application to zero, upgrades the exact candidate, and verifies Paperless 3,
PostgreSQL 17.6, Valkey 9.0.2, Tantivy search, API v10, Secret preservation, and
file hashes.

```bash
KUBECTL_BIN=/opt/homebrew/bin/kubectl \
HELM_BIN=/opt/homebrew/bin/helm \
BASE_HELM_BIN=/opt/homebrew/bin/helm \
KUBE_CONTEXT=suseai \
KUBE_INSECURE_SKIP_TLS_VERIFY=true \
NAMESPACE=paperless-ngx-v3-e2e \
RELEASE=paperless-v3-e2e \
CLEANUP_NAMESPACE=false \
scripts/paperless-e2e.sh upgrade \
  /tmp/paperless-ngx-0.4.0-candidate/paperless-ngx-0.4.0.tgz
```

Never point the runner at an existing namespace or production release. It owns
the supplied namespace and uses known test credentials.

## Evidence and cleanup

Attach the following to PR #7:

- candidate package SHA-256;
- Helm and Kubernetes versions;
- successful script output;
- Paperless `/api/status/` result with sensitive URLs removed;
- PostgreSQL and Valkey version output;
- successful `helm test` result;
- confirmation that only synthetic data was used.

After evidence is captured, remove the namespace:

```bash
kubectl --context suseai --insecure-skip-tls-verify=true \
  delete namespace paperless-ngx-v3-e2e --wait=true
```
