# Real-cluster release acceptance

The release path is **successful main Helm CI → protected real-cluster job →
publication**. The real-cluster job tests both historical upgrade baselines
against the exact CI artifact, including its monitoring integration, broker
state and namespace cleanup. The publishing job uses that artifact ID and
independently compares its SHA-256 and source commit before any release write.
Missing configuration, approval, connectivity, test success or matching outputs
blocks publication. There is no opt-out/fallback to Kind-only acceptance.

PRs continue to run on disposable GitHub-hosted Kind clusters without internal
credentials. A PR's successful test is not a substitute for acceptance of the
eventual main CI candidate. Re-running a failed release repeats acceptance;
an old acceptance result is never looked up by chart version alone.

## Safe infrastructure choice

For this public repository, use the configured disposable `ubuntu-latest`
runner and a dedicated test-cluster identity. Connect through the optional
WireGuard tunnel if the test API/DNS is internal. Restrict tunnel routing and
firewall rules to the test network. Keep GitHub/registry traffic on the normal
runner route. Prefer short-lived, narrowly scoped credentials where supported.

Do not register a persistent internal self-hosted runner with broadly available
repository labels: arbitrary PR workflows could target it. A label or a job's
`if` condition is not a runner security boundary. Organization-level runner
groups restricted to an exact trusted workflow, or a separate private acceptance
repository, require a separate reviewed setup. See GitHub's
[self-hosted runner security guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).

Use a separate cluster or an isolated vCluster with dedicated storage/network
boundaries, **not the production control plane with an administrator token**.
No production workloads, secrets or data belong in the test target. The E2E
runner deliberately uses synthetic PDFs and new namespaces, not restored
customer documents.

## One-time setup (administrator-owned, not performed by this workflow)

1. Provision a Kubernetes 1.34+ test target with a NetworkPolicy-enforcing CNI
   and a working dynamic StorageClass with `reclaimPolicy: Delete`.
2. Install maintained Prometheus Operator CRDs and an operator watching the
   newly created test namespaces. The acceptance job creates only namespaced
   Prometheus/ServiceMonitor/PrometheusRule test resources; it never installs or
   upgrades a cluster's CNI or operator. The disposable Kind job independently
   tests Cilium 1.20.1 / Operator 0.94.0 / Prometheus 3.14.0 with pinned inputs.
3. Mark this isolated target, using an administrator account:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: paperless-acceptance-system
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: acceptance-target
     namespace: paperless-acceptance-system
   data:
     purpose: paperless-isolated-release-tests
   ```

   The test identity needs read access to this marker, API discovery, the
   selected StorageClass and monitoring CRD definitions; namespace creation,
   labeling and deletion; and management of namespaced Helm/E2E resources
   (including Secrets, PVCs, RBAC, pod exec/port-forward and monitoring CRs).
   It must not modify the marker, CNI, StorageClasses, CRDs or production data.
   Ordinary RBAC cannot restrict namespace creation by a name prefix: enforce
   `paperless-ci-*` using admission policy as defense in depth, and keep this
   identity entirely out of production. Use resource quotas and an independent
   stale-test-namespace janitor for runner termination/timeout scenarios.

4. Create GitHub environment **`paperless-release-acceptance`** before supplying
   credentials. Restrict deployment branches to **main only**, require a trusted
   reviewer, and disable protection-rule bypass where your plan supports it.
   Do not store these credentials as unrestricted repository secrets.
5. Set these environment variables:

   | Variable | Value |
   | --- | --- |
   | `ACCEPTANCE_ENABLED` | `true`, only after isolation/protection is configured |
   | `ACCEPTANCE_STORAGE_CLASS` | Exact dedicated Delete-reclaim StorageClass |
   | `ACCEPTANCE_KUBECTL_VERSION` | Explicit compatible patch, default `v1.34.6`; stay within Kubernetes' supported client/server skew |

6. Set these **environment secrets**, without committing them or pasting them in
   PR comments:

   | Secret | Purpose |
   | --- | --- |
   | `ACCEPTANCE_KUBECONFIG_B64` | Base64-encoded dedicated test identity kubeconfig, with valid CA verification |
   | `ACCEPTANCE_KUBE_CONTEXT` | Exact context in that kubeconfig |
   | `ACCEPTANCE_KUBE_SERVER` | Expected HTTPS API URL, independently verified |
   | `ACCEPTANCE_WIREGUARD_CONFIG` | Optional complete `wg-quick` configuration, including internal DNS/routing if needed |

   Base64 is not encryption. Use GitHub environment secrets and rotate/revoke
   the identity and VPN key according to the cluster's credential policy. The
   runner checks the actual API URL, TLS configuration, target marker, CRDs and
   storage reclaim policy before any test namespace is created.

## Runtime and evidence

Allow time for two sequential upgrades and monitoring startup, plus cleanup;
the release acceptance job has a 120-minute ceiling. It uses distinct random
`paperless-ci-*` namespaces. Namespace ownership is checked before cleanup.
An external timeout or forcibly terminated runner can interrupt shell traps;
the target's administrator must ensure orphaned namespaces/volumes are reaped.

Only success/failure and public candidate identity are emitted in the public
Actions logs. Detailed cluster output is held in temporary private runner files
and destroyed, not uploaded as public artifacts. For failure diagnosis, reproduce
the same immutable artifact privately with the [maintainer procedure](TESTING.md),
setting `MONITORING_E2E=true`, `REQUIRE_NETWORK_POLICY_ENFORCEMENT=true` and
`E2E_STORAGE_CLASS` as above. Do not disable TLS or bypass the release dependency.

## What the additional tests prove

- The queue check reads **all configured priority buckets** for worker/configured
  queues, unacknowledged deliveries, and every expected worker's active,
  reserved and scheduled tasks. It requires three consecutive complete idle
  samples. Missing replies or unsupported transport settings fail closed. It
  does not enumerate the first API page or purge queued messages.
- A separate pod retrieves Flower metrics through both the Service and Pod IP.
  On the enforcement test paths, a differently labeled pod must be denied.
- A real operator reconciles the chart's ServiceMonitor and PrometheusRule.
  The test observes a healthy actual scrape, stored Flower samples and a firing
  test alert via the Prometheus API. Localhost availability alone is insufficient.

These checks cover the bundled synthetic test topology. Production requires its
own restored-data rehearsal for separate web/worker releases, external database
or Sentinel failover, custom Django settings, NFS/RWX, OIDC and scanner inputs.
Stop external producers before a production migration: idle snapshots cannot
prevent a new external message arriving immediately afterward. The archived
bundled PostgreSQL test image remains unsuitable as a maintained production DB.
