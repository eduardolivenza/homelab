---
name: fest-descans-postgres
description: The fest-descans PostgreSQL database — where it is configured (official postgres image in fest-page helm/api), the AppArmor signal bug that caused the 2026-10 outage and its workaround, backup/restore with pg_dump, admin users, password changes and major-version upgrades. Use for any DB task on the fest-descans website.
---

# fest-descans PostgreSQL

## Where it is defined

Not in this repo: fest-page `helm/api/templates/postgresql.yaml` (StatefulSet, Service, init-script
ConfigMap) with settings in `helm/api/values.yaml` → `postgresql:`. Deployed by the `fest-descans-api`
Application (ApplicationSet in `components/fest-descans/`, parent app `fest-descans`).
Official `postgres` image since 2026-11-02 (before: Bitnami subchart, see History below).

| Item | Value |
|---|---|
| StatefulSet / pod | `fest-descans-api-db` / `fest-descans-api-db-0`, ns `fest-descans` |
| Service | `fest-descans-api-postgresql:5432` (old name kept so the api's datasource URL didn't change; now `SPRING_DATASOURCE_URL`) |
| PVC | `data-fest-descans-api-db-0`, 5Gi, local-path (host dir under `/var/lib/rancher/k3s/storage/`) |
| Image | `docker.io/library/postgres:18.6@sha256:3a4264…` (tag + digest in values; Renovate proposes updates) |
| Data dir | PVC mounted at `/var/lib/postgresql`, PGDATA `/var/lib/postgresql/18/docker`; runs as UID 999 |
| Database | `fest-descans` |
| Users | `postgres` = superuser (secret key `postgres-password`). `fest-descans` = app user, **owner of the database, not superuser** (secret key `password`), created by the init script on first start only |
| Secret | `fest-descans-api` — SealedSecret in fest-page `helm/api/templates/sealed-secret.yaml` |
| Schema | Flyway (since the Java rewrite, 2026-11-11): migrations in fest-page `apps/api/src/main/resources/db/migration` (`V1__init.sql`, …), applied by the api itself on startup; history table `flyway_schema_history`. Before that it was Prisma (`_prisma_migrations`, may still exist in the DB) |
| Local dev / CI | fest-page `docker-compose.yml` uses `postgres:18-alpine`; the `Image (api)` PR check runs the production image + init script |
| Old Bitnami PVC | `data-fest-descans-api-postgresql-0`: kept for rollback after the migration, **delete it after 2026-11-05** (see Cleanup) |

Inside the container, local socket connections are trusted: `kubectl exec … -- psql -U postgres` needs no password.

## Current settings and why (fest-page `helm/api`)

```yaml
# values.yaml → postgresql:
image: { repository: docker.io/library/postgres, tag: "18.6", digest: sha256:… }  # never float: a restart could jump majors
startupProbe:   { initialDelaySeconds: 15, periodSeconds: 10, timeoutSeconds: 15, failureThreshold: 180 }  # 30 min (HDD recovery)
livenessProbe:  { initialDelaySeconds: 0, periodSeconds: 30, timeoutSeconds: 15, failureThreshold: 10 }
readinessProbe: { initialDelaySeconds: 5, periodSeconds: 10, timeoutSeconds: 15, failureThreshold: 6 }
terminationGracePeriodSeconds: 120          # room for a clean shutdown → no crash recovery next start
config:                                     # rendered as `postgres -c key=value`
  recovery_init_sync_method: syncfs         # crash recovery syncs the FS once instead of every file (HDD)
  checkpoint_timeout: 60s
  io_method: sync                           # outage-era workaround, candidate for removal (see below)
# templates/postgresql.yaml, container securityContext:
appArmorProfile: { type: Unconfined }       # THE FIX for the signal bug, see below
```

### Root cause of the 2026-10-29/30 outage: AppArmor blocks signals (found 2026-11-02)

Symptoms (both outages and the 2026-11-02 restarts): after `ready to accept connections` nothing
answered, ~100 backends stuck in `authentication` (`S`, `ep_poll`), io workers asleep, recovery
pausing exactly `checkpoint_timeout`, `autovacuum worker took too long to start`, minutes "in recovery
mode" on an empty DB, liveness kills (exit 137).

Cause: on this host (kernel 7.0.0-42, `kernel.apparmor_restrict_unprivileged_unconfined = 1`), the
container runtime's AppArmor profile switch is "converted to stacking", so container processes run
under the label `cri-containerd.apparmor.d//&unconfined`. The runtime-default profile only allows
signals to its own exact label, so **signals between processes of the same container are denied**.
PostgreSQL wakes its processes with `SIGURG` (latches) and `SIGUSR1` (procsignal); lost signals leave
processes asleep until something else wakes them.

Evidence (how to check again):
```bash
sudo dmesg -T | grep 'apparmor="DENIED"' | grep 'operation="signal"' | tail -3
#   apparmor="DENIED" operation="signal" … comm="postgres" … signal=urg peer="cri-containerd.apparmor.d//&unconfined"
kubectl -n fest-descans exec fest-descans-api-db-0 -- cat /proc/1/attr/current; echo
#   with the fix: unconfined      without it: cri-containerd.apparmor.d//&unconfined (enforce)
sysctl kernel.apparmor_restrict_unprivileged_unconfined kernel.apparmor_restrict_unprivileged_userns
```

- **Fix applied:** `appArmorProfile: Unconfined` on the postgres container only (fest-page PR "fix(db):
  run PostgreSQL without AppArmor confinement"). Still non-root, all capabilities dropped, no privilege
  escalation, seccomp RuntimeDefault. Verified: 0 denials, crash recovery in ~1 s.
- `io_method = sync` only removed one signal-dependent wait; it is no longer needed for correctness.
  Remove it (one line in values) after ~a week without stalls, i.e. not before 2026-11-09.
- Same bug very likely explains `rsync` hanging in the `ha-config-backup` job (multi-process, signals).
  Any multi-process program in any container can be hit: list affected programs with
  `sudo dmesg -T | grep 'apparmor="DENIED"' | grep -o 'comm="[^"]*"' | sort | uniq -c`.
- **Proper fix (open):** on the host, find why the runtime's profile change counts as "unprivileged"
  (or relax `kernel.apparmor_restrict_unprivileged_unconfined`, which weakens a host-wide protection),
  then remove `appArmorProfile: Unconfined`. Do it with Edu; it affects every container.

## Health and access

```bash
kubectl get pod fest-descans-api-db-0 -n fest-descans
kubectl exec -n fest-descans fest-descans-api-db-0 -- pg_isready -h 127.0.0.1 -U fest-descans -d fest-descans
kubectl exec -it -n fest-descans fest-descans-api-db-0 -- psql -U postgres -d fest-descans
kubectl exec -n fest-descans fest-descans-api-db-0 -- psql -U postgres -d fest-descans -tAc "select (select count(*) from \"Product\"), (select count(*) from \"Order\"), (select count(*) from \"ContactRequest\"), (select count(*) from \"AdminUser\")"
```
Row counts on 2026-11-02 (after the migration): `1|0|1|1`.

## Backup and restore

```bash
# Backup (DB must answer pg_isready)
kubectl exec -n fest-descans fest-descans-api-db-0 -- pg_dump --clean --if-exists -U postgres -d fest-descans > ~/fest-descans-$(date +%F).sql
ls -lh ~/fest-descans-*.sql; grep -c '^COPY' ~/fest-descans-*.sql   # one per table (app tables + flyway_schema_history; compare with \dt)
grep -c 'PostgreSQL database dump complete' ~/fest-descans-$(date +%F).sql   # 1
# then copy off the server (PowerShell on Edu's PC):
#   scp edu@192.168.68.53:~/fest-descans-*.sql C:\Users\EduardOlivenzaSole\Claude\Projects\LocalServer\

# Restore (also into a database that already has the schema: the dump drops and recreates)
kubectl exec -i -n fest-descans fest-descans-api-db-0 -- psql -v ON_ERROR_STOP=1 -U postgres -d fest-descans < ~/fest-descans-YYYY-MM-DD.sql
kubectl rollout restart deployment fest-descans-api -n fest-descans
```
Dumps from PG 18 end with `\restrict` / `\unrestrict <token>` lines: normal (security feature), psql 18 handles them.
**No automated backup exists yet.** Planned: nightly CronJob running `pg_dump` to a location off the laptop.

Safe stop (before reboots / maintenance): `kubectl exec -n fest-descans fest-descans-api-db-0 -- pg_ctl stop -m fast -t 120`
(PGDATA is set in the image). The container exits and Kubernetes starts it again after the reboot.

## Admin users of the website

Table `"AdminUser"` (email, name, argon2 `passwordHash`). Passwords cannot be read back.
```bash
kubectl exec -n fest-descans fest-descans-api-db-0 -- psql -U postgres -d fest-descans -c 'select email, name, "updatedAt" from "AdminUser";'
```
The fest-page seed (`packages/db/src/seed.ts`, public repo) creates `admin@festpage.com` / `admin123!`. If that still works in production, change it. Reset procedure: generate an argon2 hash with the api image (node + `argon2` package are inside it) and `UPDATE "AdminUser" SET "passwordHash" = '<hash>' WHERE email = '...'`.

## Changing DB passwords

The image and the init script read the secret only at first init (empty data dir). Rotate =
`ALTER USER "fest-descans" PASSWORD '...'` (and `ALTER USER postgres …`) inside PG **and** re-seal the
secret (see `homelab-secrets`) in the same window, then restart the api.

## Upgrading PostgreSQL

- **Minor** (18.6 → 18.x): Renovate PR in fest-page bumping tag + digest. Merge, the pod restarts, data stays.
- **Major** (18 → 19): never just a tag bump (the new server refuses the old data dir). Same procedure as the
  2026-11-02 migration: `pg_dump` → change image **and** use a new PVC (rename the StatefulSet or the
  volumeClaimTemplate) → restore → verify counts. Keep the old PVC a few days for rollback.

## Cleanup still pending

- After 2026-11-05, if all is fine: `kubectl -n fest-descans delete pvc data-fest-descans-api-postgresql-0`
  (old Bitnami data; after this a rollback to Bitnami is impossible). Also delete `~/fest-descans-migration.sql`
  on the server (copy kept on Edu's PC).
- ≥ 2026-11-09: remove `io_method: sync` (see root cause).

## History

- Until 2026-11-02: Bitnami `postgresql` subchart 13.4.4 (vendored tgz) running the Bitnami image `latest`
  pinned by digest = PG 18.4; md5 auth; `fest-descans` user created by Bitnami. Pod `fest-descans-api-postgresql-0`,
  data dir `/bitnami/postgresql/data`, UID 1001.
- 2026-10-29/30: outage, worked around with `io_method = sync` (root cause found later, see above).
- 2026-11-02: migrated to the official image (fest-page PR "Replace Bitnami PostgreSQL with the official
  postgres:18 image"): `pg_dump --clean --if-exists` → merge (ArgoCD pruned Bitnami, new empty DB) → restore →
  counts matched. The new pod restarted twice from the AppArmor bug → found the root cause, fixed the same day.
  ArgoCD showed the StatefulSet OutOfSync until `apiVersion`/`kind` were declared on the volumeClaimTemplate.
