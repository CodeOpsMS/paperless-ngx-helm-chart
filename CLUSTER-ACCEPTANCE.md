# GitHub-hosted Kubernetes release acceptance

The release path is **successful full main Helm CI → disposable GitHub Kind
acceptance → publication of the exact tested package**. No external cluster,
Rancher credentials, VPN, self-hosted runner or protected cluster environment
is required for chart publication.

Kind boots real Kubernetes nodes in containers on a fresh `ubuntu-latest`
runner; these are integration tests, not mocked Kubernetes APIs. The runner
and its cluster are disposable. No production cluster is contacted.

## Mandatory checks and immutable release binding

1. Helm CI validates both Helm lines, seven installations on Kubernetes
   1.34-1.36, four upgrade combinations, and a Cilium-backed monitoring test.
   Every job consumes the immutable candidate archive from that CI run.
2. Release branches, Paperless update PRs, main, scheduled and manually
   dispatched CI also exercise the reusable `cluster-acceptance.yml` workflow.
   It runs both historical upgrades with monitoring and enforced NetworkPolicy
   together, in fresh namespaces on a disposable Kubernetes 1.36 cluster.
3. The publishing workflow accepts only successful **main push** CI from this
   repository. It verifies run ID, attempt, source SHA and workflow path, then
   checks the paginated job results and required test steps. Missing, duplicate,
   skipped, cancelled or failed required tests block publication even if the
   workflow summary is green. Ordinary PRs and manual runs cannot publish.
4. Before publication, the same reusable acceptance workflow runs again against
   the exact main CI artifact. It installs checksum-pinned Cilium and Prometheus
   Operator in its newly created Kind cluster, then tests upgrades from chart
   `0.3.23` / Paperless `2.20.15` and chart `0.4.0-experimental.1` / Paperless
   `3.0.5`. Historical packages are downloaded unchanged and checksum-verified.
5. Only after both upgrades, monitoring checks and namespace cleanup succeed
   does acceptance emit the candidate SHA-256 and source SHA. Publication
   downloads that **same artifact ID**, independently checks the package hash,
   source identity and chart metadata, and never rebuilds the chart. Failed
   acceptance has no success outputs and cannot unblock the publishing job.

The additional acceptance job has a 90-minute ceiling and uses sequential
upgrades to bound resource usage. It shares its implementation between CI and
release, so it is tested before merge. Re-running a failed release repeats this
acceptance; a previous chart version's acceptance is never reused. The artifact
resolver supports partial CI reruns by selecting the newest unexpired candidate
from the same run at or before the tested attempt. The release always retests
those exact bytes. An expired or missing artifact requires a new CI run, not a
local rebuild or a bypass.

The GitHub-hosted jobs use the repository's read-only Actions/contents token,
not cluster secrets. Only the final publishing job has release/package write
permissions. There is no `ACCEPTANCE_ENABLED` switch or external infrastructure
requirement on this mandatory path.

## What the cluster tests prove

- Both historical upgrades preserve synthetic documents, metadata, PVC
  identities, mounted-file contents and database credentials. The tests exercise
  logical database restore, search-query migration and ingestion after upgrade.
- The queue check reads **all configured priority buckets**, unacknowledged
  deliveries and every expected worker's active, reserved and scheduled tasks.
  Three consecutive complete idle samples are required. Missing replies or
  unsupported transport settings fail closed; queued messages are not purged.
- A separate pod retrieves Flower metrics through both Service and Pod IP.
  In Cilium-backed jobs, a differently labeled pod must be denied on both paths.
- A real operator reconciles the chart's ServiceMonitor and PrometheusRule.
  Prometheus must observe a healthy actual scrape, stored Flower samples and a
  firing test alert. Localhost availability alone is insufficient.

The ordinary install/upgrade matrix retains Kind's basic CNI; NetworkPolicy
presence alone there does not prove enforcement. The dedicated monitoring job
and both upgrades in the shared acceptance job enforce it using Cilium.

## Optional external-cluster rehearsal

An external cluster test is **optional for chart publication** and remains
available through [TESTING.md](TESTING.md) and
`.github/scripts/run-real-cluster-acceptance.sh`. It is not automatically
dispatched and its credentials are not needed by GitHub Actions. Keep external
credentials local; do not upload production kubeconfig or VPN keys to CI.

For the strict external wrapper, provision an isolated test cluster or vCluster
with a NetworkPolicy-enforcing CNI, preinstalled Prometheus Operator/CRDs and a
dedicated dynamic StorageClass with `reclaimPolicy: Delete`. An administrator
must create ConfigMap `acceptance-target` in namespace
`paperless-acceptance-system`, with data
`purpose: paperless-isolated-release-tests`. The wrapper never installs or
changes an existing cluster's CNI, operator or storage classes.

Use a dedicated test identity, verified HTTPS API URL, valid CA trust and a
locally downloaded immutable candidate. Supply `KUBECONFIG`, `KUBE_CONTEXT`,
`EXPECTED_KUBE_SERVER`, `E2E_STORAGE_CLASS` and `ACCEPTANCE_ENABLED=true` only to
that manual wrapper. Set `SOURCE_SHA`, `GITHUB_RUN_ID` and `GITHUB_RUN_ATTEMPT`
to the downloaded candidate's source/run, and `GITHUB_OUTPUT` to a private local
evidence file. Detailed external cluster logs are withheld from stdout and
discarded; reproduce individual E2E commands privately for troubleshooting.

The wrapper requires both baseline upgrades, monitoring, network enforcement
and namespace cleanup. Missing credentials, invalid TLS, target-marker mismatch
or failed tests remain failures of this optional rehearsal, never successes.
Keep this identity out of production. Apply quotas, namespace admission rules
and independent stale-namespace cleanup for forcibly terminated test clients.

## Limits before a production upgrade

These checks cover the bundled synthetic topology, not the exact production
environment. Rehearse restored data separately for split web/worker releases,
external databases, Sentinel failover, custom Django settings, NFS/RWX/CSI,
Rancher/RKE2 configuration, OIDC and scanner inputs. A green chart release is
not evidence that these site-specific integrations were tested.

Stop external producers before a production migration: idle snapshots cannot
prevent a new external message arriving immediately afterward. The archived
bundled PostgreSQL test image remains unsuitable as a maintained production DB.
