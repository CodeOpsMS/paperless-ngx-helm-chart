# Upgrade to experimental chart 0.4.0-experimental.2 and Paperless-ngx 3

Chart `0.4.0-experimental.2` is an opt-in prerelease that upgrades Paperless-ngx
from 2.20.15 to 3.1.0. Chart `0.3.23` remains the stable default and normal Helm
search/install operations do not select this prerelease. PostgreSQL stays on
17.6 for the tested bundled upgrade path, while Valkey receives the compatible
9.0.5 update. Keeping the database engine unchanged deliberately isolates the
Paperless database and search migrations from a database-engine major upgrade.

This procedure is mandatory for existing installations. Test it with a restored
copy of production data before scheduling the production change.

## Supported starting point

- The running Paperless version must be exactly `2.20.15`.
- For an existing Paperless 2 installation, migration
  `documents.1075_workflowaction_order` must already be applied. Paperless 3
  refuses to start from any other Paperless 2 migration state.
- Use chart `0.3.23` as the tested baseline.
- Upgrade the existing database and PVCs in place. Upstream only recommends
  import between matching Paperless versions, and an import must target a fully
  empty installation. Treat a Paperless 2 export as supplemental backup, not as
  a guaranteed Paperless 3 migration or rollback path.
- Upgrade directly to `3.1.0`; do not stop on the broken `3.0.1` migration.
- Do not combine this change with a PostgreSQL, Valkey, storage-class, ingress,
  or authentication-provider migration.
- Ensure Kubernetes is at least `1.34` and the node CPU meets the Paperless 3
  x86-64-v2 baseline on amd64.

Kubernetes 1.34 is an intentional support-policy floor aligned with the tested
1.34-1.36 matrix, not the technical introduction version of every rendered API.
Clusters below that maintained/tested floor are unsupported and rejected by the
chart metadata.

Upgrade older Paperless installations to 2.20.15 first and validate them before
continuing. Before the maintenance window, confirm the required migration:

```bash
kubectl exec deployment/paperless-ngx -n paperless-ngx -- \
  python3 manage.py showmigrations documents | \
  grep -F '[X] 1075_workflowaction_order'
```

## Paperless 3 preflight

Review the official [v3 migration guide](https://docs.paperless-ngx.com/migration-v3/)
and resolve every applicable item:

- Preserve `PAPERLESS_SECRET_KEY` across every Paperless pod. Rotating it
  invalidates existing sessions and signed tokens, and Paperless 3 also uses it
  for signed Celery messages.
- Decrypt documents and thumbnails before upgrading; Paperless 3 removes the
  deprecated encryption support.
- Drain document consumption, email fetching, workflows, and Celery tasks, and
  confirm the broker queue is empty. Paperless 3 changes the Celery serializer
  and no longer accepts queued Paperless 2 messages. Task results also move from
  the database to Redis/Valkey and expire after one hour.
- Replace `PAPERLESS_CONSUMER_POLLING` with
  `PAPERLESS_CONSUMER_POLLING_INTERVAL`.
- Replace `PAPERLESS_CONSUMER_INOTIFY_DELAY` with
  `PAPERLESS_CONSUMER_STABILITY_DELAY`.
- Remove `PAPERLESS_CONSUMER_POLLING_DELAY`,
  `PAPERLESS_CONSUMER_POLLING_RETRY_COUNT`, and
  `PAPERLESS_CONSUMER_BARCODE_SCANNER`.
- Convert consumer ignore patterns from fnmatch syntax to JSON lists of regular
  expressions and use `PAPERLESS_CONSUMER_IGNORE_DIRS` for directories. File
  expressions are evaluated with Python `re.search()` against the filename only,
  and both lists extend immutable built-in rules. Do not copy a glob unchanged:
  for example, `._*` as a regex matches nearly every non-empty filename.
- Decide whether duplicate documents should remain accepted. Paperless 3 accepts
  them by default. `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` rejects and
  deletes the duplicate input file; this is not identical to Paperless 2's
  default, which rejected it but retained the input file.
- Replace deprecated database SSL, timeout, and pool variables with a single
  `PAPERLESS_DB_OPTIONS` string.
- Replace removed OCR/archive combinations with `PAPERLESS_OCR_MODE` values
  `auto`, `force`, `redo`, or `off` and `PAPERLESS_ARCHIVE_FILE_GENERATION`.
  If the Paperless 2 installation depended on an archive copy being generated
  for every document, explicitly set `PAPERLESS_OCR_MODE=auto` and
  `PAPERLESS_ARCHIVE_FILE_GENERATION=always`; the Paperless 3 defaults may omit
  an archive for born-digital PDFs.
- Update pre- and post-consume scripts to use the documented environment
  variables instead of positional arguments.
- Update API clients to version 9 or 10; Paperless 3 no longer supports API
  versions below 9 and unversioned requests now use version 10. Review clients
  that consume Task or SavedView responses. The automated acceptance test uses
  API version 10.
- Remove `PAPERLESS_SEARCH_LANGUAGE` for this 3.1.0 release. Explicitly setting
  it can crash the migration initializer before startup; Paperless derives the
  default search language from the OCR language. The chart schema blocks the
  variable until the upstream 3.1 fix is available (see upstream
  [issue #13767](https://github.com/paperless-ngx/paperless-ngx/issues/13767)).
- Review OIDC `token_auth_method`, reverse-proxy trusted proxy settings, and
  login rate-limit client-IP handling.
- If the remote OCR parser is used, record that it always creates an archive
  copy even when `PAPERLESS_ARCHIVE_FILE_GENERATION=never`.
- Record that task history is cleared and the old database-backed Celery result
  tables are removed during the migration.
- Review saved searches using notes or custom fields. Tantivy uses
  `notes.note:` and `custom_fields.value:` field names. Explicit old field names
  are migrated, but unqualified search terms cannot be rewritten reliably and
  must be validated manually. Inventory and test complex Whoosh queries too:
  saved views using wildcards or regex-like character classes can remain invalid
  in 3.1.0 (see upstream
  [issue #13568](https://github.com/paperless-ngx/paperless-ngx/issues/13568)).
- Budget time and storage I/O for the first start: Paperless converts every
  present original/archive file checksum from MD5 to SHA-256 sequentially and
  rebuilds the incompatible Whoosh index as Tantivy. A missing media file is
  only warned about and retains its old MD5 value. Update integrations that
  assume a 32-character checksum.
- Ensure the data PVC has generous free space and monitor Tantivy index growth.
  Paperless 3.1.0 can retain orphaned Tantivy segments when several processes
  write the index; `document_index optimize` does not compact Tantivy, and a
  recreate/reindex only reduces the growth temporarily until an upstream fix
  (see upstream
  [issue #13679](https://github.com/paperless-ngx/paperless-ngx/issues/13679)).
- Review workflow actions that assign custom-field values. Paperless 3.1.0 can
  persist an empty value and later overwrite a manually assigned value; it also
  cannot reliably set `false` or `0` in that action. Disable or correct affected
  workflows until an upstream release containing
  [fix #13630](https://github.com/paperless-ngx/paperless-ngx/pull/13630) is
  deployed.
- Check amd64 nodes for the `sse4_2` CPU flag and move the workload to nodes
  that meet the x86-64-v2 baseline when it is absent. Disabling classifier
  training is not sufficient for the official 3.1.0 image: document consumption
  can still import an incompatible NumPy build. The upstream fix is targeted at
  Paperless 3.1 and is not part of this experimental release (see upstream
  [issue #13429](https://github.com/paperless-ngx/paperless-ngx/issues/13429)).
- Review mail rules whose `maximum_age` exceeds 32767. Paperless clamps those
  values to 32767 during the database migration.
- For SQLite, verify WAL/locking behavior on the actual PVC and keep a single
  replica, especially on NFS/RWX storage. For MariaDB with binary logging, use
  `binlog_format=ROW`. The chart's default PostgreSQL path is unaffected.
- Rebuild and retest custom images and native extensions. Paperless 3 requires
  Python 3.11 or newer; the official 3.1.0 image uses Python 3.12 on Debian
  Trixie.
- If an external Tika service is configured, pin `apache/tika:3.3.1.0`; do not
  use `latest`, which now resolves to Tika 4 and breaks Office/EML consumption
  with Paperless 3.1.0 (see upstream
  [issue #13755](https://github.com/paperless-ngx/paperless-ngx/issues/13755)).

The chart sets the now-required `PAPERLESS_DBENGINE=postgresql` explicitly for
its default database. Before shutting down Paperless 2, run its documented
`decrypt_documents` management command if document or thumbnail encryption was
ever enabled, and verify that no encrypted files remain.

The `0.4.0-experimental.2` values schema rejects chart-managed settings and
removed Paperless 2 variables when they are supplied through `env`.

## Values migration

Create a new values file from the `0.4.0-experimental.2` defaults. Do not pass
the old file unchanged and do not use `--reuse-values`.

| Chart 0.3.x | Chart 0.4.0-experimental.2 |
|-------------|----------------------------|
| `config.database.pass` for an external database | `config.database.password` or, preferably, `config.database.existingSecret` |
| `config.database.name` / `user` for the bundled database | Keep their new defaults and configure `postgresql.auth.database` / `username` |
| `config.database.pass` for the bundled database | Remove it; Paperless now reads the exact PostgreSQL dependency Secret/key |
| Static bundled `postgresql.auth.password` / `postgresPassword` defaults | Empty values generate random credentials on fresh installs and preserve the existing PostgreSQL Secret during an in-cluster upgrade |
| `config.database.existingSecret.passKey` | `config.database.existingSecret.passwordKey` |
| `config.database.sslmode: require` | `config.database.options: sslmode=require` |
| `env.PAPERLESS_SECRET_KEY` | `config.secretKey.existingSecret` or the preserved chart-generated Secret |
| `config.redis.url` containing credentials | Prefer `config.redis.existingSecret.name` and `.urlKey` |
| `env.<NAME>.valuesFrom` | `env.<NAME>.valueFrom` |
| Inline `config.oidcProviders` containing credentials | Prefer `env.PAPERLESS_SOCIALACCOUNT_PROVIDERS.valueFrom.secretKeyRef`; the schema rejects configuring both sources |
| `env.PAPERLESS_CONSUMER_INOTIFY_DELAY` | `env.PAPERLESS_CONSUMER_STABILITY_DELAY` |
| `env.PAPERLESS_SEARCH_LANGUAGE` | Remove it for Paperless 3.1.0; the schema rejects this known startup-breaking setting |
| API clients using versions 1-8 | API version 9 or 10 |
| Default rolling Deployment update | Zero-surge `RollingUpdate` (`maxSurge: 0`, `maxUnavailable: 100%`); the required scale-to-zero step below is what prevents mixed v2/v3 processes during the major migration |
| `serviceAccount.automount: true` default | Default is now `false`; enable it explicitly only if an integration in the Paperless pod needs the Kubernetes API token |
| `persistence.enabled: true` | Chart-managed Paperless PVCs now default to `persistence.retain: true` and survive Helm uninstall |
| Dependency-wide registry/OpenShift values | `global.imageRegistry`, `global.security.allowInsecureImages`, and `global.compatibility.openshift.adaptSecurityContext` remain supported; `global.image.registry` controls the Paperless image |
| `livenessProbe.httpGet.path` | `livenessProbe.enabled: true` and `livenessProbe.path` |
| `readinessProbe.httpGet.path` | `readinessProbe.enabled: true` and `readinessProbe.path` |
| `livenessProbe.httpGet.port` / `readinessProbe.httpGet.port` | Remove; both probes now use the fixed named port `http` |
| Empty or omitted legacy probe object | Set the corresponding `enabled: false` only when the probe should be disabled; otherwise start from the experimental defaults |

Validate the migrated file before touching the cluster:

```bash
candidate=/tmp/paperless-ngx-0.4.0-experimental.2.tgz
helm pull paperless/paperless-ngx \
  --version 0.4.0-experimental.2 \
  --destination /tmp

helm lint "$candidate" \
  --strict \
  --values paperless-0.4-values.yaml

helm template paperless-ngx "$candidate" \
  --namespace paperless-ngx \
  --values paperless-0.4-values.yaml \
  >/tmp/paperless-0.4-rendered.yaml
```

If an external Secret is not configured, the chart preserves its generated
`PAPERLESS_SECRET_KEY` using a Kubernetes lookup. A GitOps renderer without
cluster access cannot perform that lookup; production GitOps installations
should use `config.secretKey.existingSecret`.

The bundled PostgreSQL credentials follow the same upgrade-safety principle,
but their source is exclusively `postgresql.auth`. With empty password values,
the Bitnami dependency looks up and reuses the existing PostgreSQL Secret during
an in-cluster Helm upgrade; on a fresh install it generates random values.
Paperless references that dependency Secret directly. For offline GitOps
rendering, set `postgresql.auth.existingSecret` and provide the configured
`postgresql.auth.secretKeys`. Do not copy a bundled password into
`config.database.password`; the schema rejects that ambiguous configuration.

Do not increment `postgresql.credentialsRevision` during this Paperless-only
upgrade: with unchanged credentials the revision must remain `0` (or retain its
previous value). For a separate, planned credential rotation, update the
database or externally managed Secret first, increment
`postgresql.credentialsRevision` in the same reviewed Helm change, and verify
the Paperless rollout. The revision is deliberately non-sensitive; never put a
password or password hash in it or in another pod-template annotation.

Pod annotations no longer contain deterministic hashes of the complete
`config` or `env` blocks because those values may include low-entropy
credentials. Instead, set the non-sensitive `config.secretRevision` to a new
integer whenever another `config` value changes data in the chart-managed
Secret (including `config.oidcProviders`), a scalar `env` value changes, or an
externally managed Secret is updated in place. Keep it at `0` for this upgrade
unless such a change is part of the reviewed values migration. Never copy a
credential or credential hash into the revision.

The bundled Valkey integration supports neither authentication nor TLS because
the parent chart constructs an unauthenticated in-cluster URL. If either is
required, use a separately managed broker, set `valkey.internal=false`, and
reference its complete `redis://` or `rediss://` URL with
`config.redis.existingSecret`. Do not enable `valkey.auth.enabled` or
`valkey.tls.enabled` on the bundled dependency. Likewise,
`postgresql.namespaceOverride` is unsupported: Paperless and the bundled
PostgreSQL credential Secret must remain in the Helm release namespace.

## Backup and restore rehearsal

Take a storage- and database-consistent backup after the task queue is empty.
Keep backup files encrypted and outside the cluster.

1. Export the release and values:

   ```bash
   helm get values paperless-ngx -n paperless-ngx --all \
     >paperless-values-before-0.4.yaml
   helm get manifest paperless-ngx -n paperless-ngx \
     >paperless-manifest-before-0.4.yaml
   ```

2. Back up the application Secret. This file contains credentials and must be
   protected accordingly:

   ```bash
   kubectl get secret paperless-ngx -n paperless-ngx -o yaml \
     >paperless-secret-before-0.4.yaml
   ```

3. Create a PostgreSQL logical dump from the existing PostgreSQL 17 pod:

   ```bash
   POSTGRES_POD=$(kubectl get pod -n paperless-ngx \
     -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=paperless-ngx \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n paperless-ngx "$POSTGRES_POD" -- \
     env PGPASSWORD='<database-password>' \
     pg_dump -U paperless -d paperless --no-owner --no-privileges \
     >paperless-postgresql-17.sql
   ```

4. Snapshot or back up the Paperless data/media/consume/export PVC and the
   PostgreSQL PVC using storage-provider tooling. A database dump alone is not
   a complete Paperless backup.

5. Produce and retain document checksums from the media volume.

6. Restore the database dump into a temporary PostgreSQL 17 database or
   instance and verify that it contains the expected users and documents. The
   automated upgrade test performs this logical restore rehearsal for its
   synthetic dataset with a clean `psql` session, stop-on-error behavior, and a
   single transaction. Create the empty target from `template0`, and use the
   same fail-closed options for a manual rehearsal:

   ```bash
   PGPASSWORD='<database-password>' createdb \
     -U paperless -T template0 paperless_restore
   PGPASSWORD='<database-password>' psql \
     -X --set=ON_ERROR_STOP=1 --single-transaction \
     -U paperless -d paperless_restore \
     <paperless-postgresql-17.sql
   ```

   Before the dump and after the restore, compare exact row counts for at least
   `auth_user`, `documents_document`, `documents_tag`,
   `documents_correspondent`, `documents_documenttype`,
   `documents_customfield`, and `documents_savedview`. A successful `psql`
   process alone is not sufficient restore evidence.

Do not proceed until both the database restore and persistent-file restore have
been rehearsed.

## Controlled upgrade

1. Announce maintenance and stop all new consumers and integrations.
2. Confirm that uploaded documents are processed and no relevant task remains
   pending or running. Confirm the Redis/Valkey broker queue is empty.
3. Disable autoscaling in the migration values (`autoscaling.enabled: false`,
   `replicaCount: 1`) and remove the old HPA before scaling down. Otherwise its
   controller can scale the Paperless 2 Deployment back up during migration.
   Leave PostgreSQL and Valkey running:

   ```bash
   paperless_v2_pods=$(kubectl get pod -n paperless-ngx \
     -l app.kubernetes.io/instance=paperless-ngx,app.kubernetes.io/name=paperless-ngx \
     -o name)
   test -n "$paperless_v2_pods"
   kubectl delete hpa paperless-ngx -n paperless-ngx --ignore-not-found
   kubectl scale deployment paperless-ngx -n paperless-ngx --replicas=0
   kubectl rollout status deployment/paperless-ngx -n paperless-ngx --timeout=5m
   for pod in $paperless_v2_pods; do
     kubectl wait --for=delete "$pod" -n paperless-ngx --timeout=5m
   done
   remaining=$(kubectl get pod -n paperless-ngx \
     -l app.kubernetes.io/instance=paperless-ngx,app.kubernetes.io/name=paperless-ngx \
     --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
     -o name)
   test -z "$remaining"
   ```

   The chart defaults to a zero-surge, fully unavailable `RollingUpdate` so it
   remains compatible with Helm 4 server-side apply and does not create an
   extra application pod. It does **not** replace this explicit shutdown: only
   scaling to zero and waiting for completion proves that no Paperless 2
   process remains when Paperless 3 starts.

4. Upgrade with the reviewed values file and the exact validated chart package:

   ```bash
   candidate=/tmp/paperless-ngx-0.4.0-experimental.2.tgz
   test -f "$candidate"
   helm upgrade paperless-ngx "$candidate" \
     --namespace paperless-ngx \
     --reset-values \
     --values paperless-0.4-values.yaml \
     --wait \
     --timeout 40m
   kubectl rollout status deployment/paperless-ngx \
     -n paperless-ngx --timeout=40m
   kubectl wait pod -n paperless-ngx \
     -l app.kubernetes.io/instance=paperless-ngx,app.kubernetes.io/name=paperless-ngx,app.kubernetes.io/component=web \
     --for=condition=Ready --timeout=40m
   ```

   Do not use `--reuse-values`, `--atomic`, or `--cleanup-on-fail`. An automatic
   Helm rollback cannot reverse Paperless database migrations safely.
   The explicit rollout and readiness waits are required because a fully
   unavailable RollingUpdate can satisfy Helm's availability threshold before
   the new Paperless pod is ready.

   The zero-surge, fully unavailable settings remain active after this upgrade
   and cause downtime on every later application rollout. After accepting the
   completed migration, availability-oriented values such as `maxSurge: 1` and
   `maxUnavailable: 0` may be tested and applied for subsequent upgrades.

5. Follow the Paperless logs. The first Paperless 3 start applies database and
   application migrations, converts document checksums, and rebuilds the
   incompatible Whoosh search index as Tantivy. The default startup probe permits
   up to 30 minutes; increase the startup probe, Helm timeout, and both explicit
   `kubectl` wait timeouts together before upgrading a very large archive rather
   than interrupting these operations.

## Acceptance checks

Before ending maintenance, verify:

- the Paperless pod is Ready and all probes are healthy;
- `/api/status/` reports Paperless 3.1.0, PostgreSQL status `OK`, no unapplied
  migrations, a healthy Redis/Valkey connection, and a healthy search index;
- PostgreSQL still reports version 17.6 and uses the original PVC;
- Valkey still reports version 9.0.5;
- every pre-upgrade PVC name and Kubernetes UID is unchanged;
- ownership and modes of the Paperless data, media, consume, and export mount
  roots are unchanged (or any deliberate correction is reviewed and recorded);
- users and authentication providers still work;
- document counts, tags, correspondents, document types, notes, custom fields,
  saved views, and permissions match the pre-upgrade inventory;
- representative documents download with their original hashes;
- every present original/archive file has a 64-character SHA-256 checksum and
  every integration that consumes it has been updated; investigate any remaining
  32-character value as evidence of a missing media file;
- new documents can be consumed;
- Tantivy returns expected document, note, and custom-field search results;
- pre-/post-consume scripts work without positional arguments;
- `helm test paperless-ngx -n paperless-ngx --logs` succeeds;
- Kubernetes events and Paperless logs contain no repeated errors.

Keep autoscaling disabled until every acceptance check has passed. Re-enable the
HPA only in a separate reviewed Helm change.

## Recovery

Do not run `helm rollback` against a database already migrated by Paperless 3.

If acceptance fails:

1. Stop Paperless 3 immediately.
2. Preserve diagnostics from pods, events, and logs.
3. Restore the PostgreSQL 17 database from the validated pre-upgrade dump or
   storage snapshot.
4. Restore the Paperless persistent volume from the matching backup.
5. Restore the original Secret, especially the exact `PAPERLESS_SECRET_KEY`.
6. Reinstall chart 0.3.23 with Paperless 2.20.15 and the saved pre-upgrade values.
7. Re-run document-count, authentication, search, and file-hash checks before
   reopening the service.

The bundled `bitnamilegacy/postgresql` 17.6 image remains in this release only
to keep the tested Paperless 2-to-3 migration baseline unchanged. Bitnami
Legacy images are archived and do not receive normal maintenance. New and
production deployments should use a maintained external PostgreSQL 17 service
(currently PostgreSQL 17.10) with `postgresql.enabled=false`, an explicit
`config.database.host`, and externally managed credentials. This PR does not
perform an automatic PostgreSQL 18 migration; that requires a separate,
rehearsed database upgrade after Paperless 3 is stable.
