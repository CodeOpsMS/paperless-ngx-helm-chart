# Upgrade to chart 0.4.0 and Paperless-ngx 3

Chart 0.4.0 upgrades Paperless-ngx from 2.20.15 to 3.0.5. PostgreSQL stays on
17.6 and Valkey stays on 9.0.2. Keeping those services unchanged deliberately
isolates the Paperless database and search migrations from database-engine and
broker major upgrades.

This procedure is mandatory for existing installations. Test it with a restored
copy of production data before scheduling the production change.

## Supported starting point

- The running Paperless version must be exactly `2.20.15`.
- Use chart `0.3.23` as the tested baseline.
- Do not combine this change with a PostgreSQL, Valkey, storage-class, ingress,
  or authentication-provider migration.
- Ensure Kubernetes is at least `1.34` and the node CPU meets the Paperless 3
  x86-64-v2 baseline on amd64.

Upgrade older Paperless installations to 2.20.15 first and validate them before
continuing.

## Paperless 3 preflight

Review the official [v3 migration guide](https://docs.paperless-ngx.com/migration-v3/)
and resolve every applicable item:

- Preserve or deliberately rotate `PAPERLESS_SECRET_KEY`. Rotating it invalidates
  existing sessions and signed tokens.
- Decrypt documents and thumbnails before upgrading; Paperless 3 removes the
  deprecated encryption support.
- Drain document consumption, email fetching, workflows, and Celery tasks.
- Replace `PAPERLESS_CONSUMER_POLLING` with
  `PAPERLESS_CONSUMER_POLLING_INTERVAL`.
- Replace `PAPERLESS_CONSUMER_INOTIFY_DELAY` with
  `PAPERLESS_CONSUMER_STABILITY_DELAY`.
- Remove `PAPERLESS_CONSUMER_POLLING_DELAY`,
  `PAPERLESS_CONSUMER_POLLING_RETRY_COUNT`, and
  `PAPERLESS_CONSUMER_BARCODE_SCANNER`.
- Convert consumer ignore patterns from fnmatch syntax to regular expressions
  and use `PAPERLESS_CONSUMER_IGNORE_DIRS` for directories.
- Decide whether duplicate documents should remain accepted. Set
  `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` to retain rejection behavior.
- Replace deprecated database SSL, timeout, and pool variables with a single
  `PAPERLESS_DB_OPTIONS` string.
- Replace removed OCR/archive combinations with `PAPERLESS_OCR_MODE` values
  `auto`, `force`, `redo`, or `off` and `PAPERLESS_ARCHIVE_FILE_GENERATION`.
- Update pre- and post-consume scripts to use the documented environment
  variables instead of positional arguments.
- Update API clients to version 9 or 10; Paperless 3 no longer supports API
  versions below 9. The automated acceptance test uses API version 10.
- Review OIDC `token_auth_method`, reverse-proxy trusted proxy settings, and
  login rate-limit client-IP handling.
- If the remote OCR parser is used, record that it always creates an archive
  copy even when `PAPERLESS_ARCHIVE_FILE_GENERATION=never`.
- Record that task history is cleared during the migration.
- Review saved searches using notes or custom fields. Tantivy uses
  `notes.note:` and `custom_fields.value:` field names.
- Check amd64 nodes for the `sse4_2` CPU flag. On older processors that lack
  the x86-64-v2 baseline, disable classifier training with
  `PAPERLESS_TRAIN_TASK_CRON=disable` or move the workload to supported nodes.
- Review mail rules whose `maximum_age` exceeds 32767. Paperless clamps those
  values to 32767 during the database migration.

The chart sets the now-required `PAPERLESS_DBENGINE=postgresql` explicitly for
its default database. Before shutting down Paperless 2, run its documented
`decrypt_documents` management command if document or thumbnail encryption was
ever enabled, and verify that no encrypted files remain.

The 0.4.0 values schema rejects chart-managed settings and removed Paperless 2
variables when they are supplied through `env`.

## Values migration

Create a new values file from the 0.4.0 defaults. Do not pass the old file
unchanged and do not use `--reuse-values`.

| Chart 0.3.x | Chart 0.4.0 |
|-------------|-------------|
| `config.database.pass` | `config.database.password` |
| `config.database.existingSecret.passKey` | `config.database.existingSecret.passwordKey` |
| `config.database.sslmode: require` | `config.database.options: sslmode=require` |
| `env.PAPERLESS_SECRET_KEY` | `config.secretKey.existingSecret` or the preserved chart-generated Secret |
| `config.redis.url` containing credentials | Prefer `config.redis.existingSecret.name` and `.urlKey` |
| `env.<NAME>.valuesFrom` | `env.<NAME>.valueFrom` |
| `env.PAPERLESS_CONSUMER_INOTIFY_DELAY` | `env.PAPERLESS_CONSUMER_STABILITY_DELAY` |
| API clients using versions 1-8 | API version 9 or 10 |

Validate the migrated file before touching the cluster:

```bash
helm lint paperless/paperless-ngx \
  --version 0.4.0 \
  --strict \
  --values paperless-0.4-values.yaml

helm template paperless-ngx paperless/paperless-ngx \
  --version 0.4.0 \
  --namespace paperless-ngx \
  --values paperless-0.4-values.yaml \
  >/tmp/paperless-0.4-rendered.yaml
```

If an external Secret is not configured, the chart preserves its generated
`PAPERLESS_SECRET_KEY` using a Kubernetes lookup. A GitOps renderer without
cluster access cannot perform that lookup; production GitOps installations
should use `config.secretKey.existingSecret`.

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
   synthetic dataset.

Do not proceed until both the database restore and persistent-file restore have
been rehearsed.

## Controlled upgrade

1. Announce maintenance and stop all new consumers and integrations.
2. Confirm that uploaded documents are processed and no relevant task remains
   pending or running.
3. Scale only the Paperless Deployment to zero. Leave PostgreSQL and Valkey
   running:

   ```bash
   kubectl scale deployment paperless-ngx -n paperless-ngx --replicas=0
   kubectl rollout status deployment/paperless-ngx -n paperless-ngx --timeout=5m
   ```

4. Upgrade with the reviewed values file and the exact validated chart package:

   ```bash
   helm upgrade paperless-ngx paperless/paperless-ngx \
     --version 0.4.0 \
     --namespace paperless-ngx \
     --reset-values \
     --values paperless-0.4-values.yaml \
     --wait \
     --timeout 30m
   ```

   Do not use `--reuse-values`, `--atomic`, or `--cleanup-on-fail`. An automatic
   Helm rollback cannot reverse Paperless database migrations safely.

5. Follow the Paperless logs. The first Paperless 3 start applies database and
   application migrations and rebuilds the incompatible Whoosh search index as
   Tantivy. The default startup probe permits up to 30 minutes.

## Acceptance checks

Before ending maintenance, verify:

- the Paperless pod is Ready and all probes are healthy;
- `/api/status/` reports Paperless 3.0.5, PostgreSQL status `OK`, no unapplied
  migrations, a healthy Redis/Valkey connection, and a healthy search index;
- PostgreSQL still reports version 17.6 and uses the original PVC;
- Valkey still reports version 9.0.2;
- users and authentication providers still work;
- document counts, tags, correspondents, document types, notes, custom fields,
  saved views, and permissions match the pre-upgrade inventory;
- representative documents download with their original hashes;
- new documents can be consumed;
- Tantivy returns expected document, note, and custom-field search results;
- pre-/post-consume scripts work without positional arguments;
- `helm test paperless-ngx -n paperless-ngx --logs` succeeds;
- Kubernetes events and Paperless logs contain no repeated errors.

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

PostgreSQL 18, a maintained replacement for the archived Bitnami Legacy image,
and later Valkey updates require separate changes and migration tests after the
Paperless 3 upgrade is stable.
