# History

## Before 2026-10-28 (starting point)
- K3s single node on the laptop, ArgoCD installed with `kubectl apply` of upstream manifests.
- fest-page repo held the ApplicationSet (web/admin/api/**cloudflared**), and the tunnel route for HA.
- Home Assistant deployed through an ArgoCD Application **created by hand** (values inline, image `stable`).
- Secrets created by hand (`ghcr-credentials`, `fest-descans-api`, `cloudflared-credentials`, an ArgoCD repo token).
- Leftovers: orphan ConfigMap `home-assistant-config` (thermostat template sensor, not mounted).

## 2026-10-28 — GitOps migration
1. Inventory taken with `kubectl get ... -o yaml` dumps.
2. Created public repo `homelab` (app-of-apps).
3. Installed Sealed Secrets **first** (chart repo URL must be `https://bitnami.github.io/sealed-secrets`; `bitnami-labs.github.io` 404s).
4. Sealed the existing secrets by reading them from the cluster (no need to know values). Existing unmanaged secrets had to be annotated `sealedsecrets.bitnami.com/managed=true` so the controller would take them over.
5. Applied `bootstrap/root-app.yaml`. Same-named apps (`fest-descans`, `home-assistant`) were adopted without redeploy. The old `fest-descans-cloudflared` app disappeared and the new `cloudflared` (own namespace) took over the tunnel with no downtime.
6. Deleted the stale ArgoCD repo credential for fest-page (caused `Sync: Unknown`).
7. Cleaned fest-page (removed `helm/cloudflared/` and `argocd/`).
- **Lesson:** applying the root app before the secrets exist would have pruned the old cloudflared before the new one had credentials → outage. Order: sealed-secrets → seal → root app.

## 2026-10-28 evening — HA crashloop
- Laptop rebooted ~20:17 UTC (first boot on kernel 7.0.0-42). HA crash-looped (83 restarts): liveness killed it after ~60 s while it was still loading custom integrations from the HDD.
- Fix: startupProbe; then had to delete the pod because a crash-looping StatefulSet pod is not replaced automatically.
- HA image pinned to the version actually running (2026.6.4, read from `/config/.HA_VERSION`).

## 2026-10-29 — performance incident
- Load average ~26 with idle CPU, I/O wait 33–51 %, constant swapping, node flapping `NotReady`, HA killed by liveness (exit 137).
- Root cause: 3.2 GB RAM + swap on a 5400 rpm HDD. DB size was tiny (18 MB), not the issue.
- Fixes: tolerant HA liveness, removed Traefik / Dex / notifications, reboot. Load dropped to ~1, I/O wait 6–12 %.
- Recommended SSD (+RAM).

## 2026-10-29 — Renovate, cloudflared security update, HA upgrades
- Renovate set up (Silent → Interactive). Merged: cloudflared 2024.12.2 → 2026.10.5 (Cloudflare security notice: emSign certificates, needed ≥ 2026.10.2/10.3), ArgoCD 3.4.4 → 3.5.6, HA chart 0.3.67 → 0.3.89, HA 2026.6.4 → 7.4 → 8.3 → 9.4 → 10.4 one month at a time.
- Note for HA ≥ 2026.8: the `http:` YAML block is deprecated (moved to `.storage/http`, removal in 2027.2). External access through the tunnel kept working.
- ArgoCD UI exposed on NodePort 30443 (LAN only).

## 2026-10-29/30 — fest-descans PostgreSQL outage
- PostgreSQL (Bitnami image `latest` = PG 18.4) stuck in a restart loop after unclean shutdowns.
- Iterations: pinned image digest; startupProbe/liveness tolerance; terminationGracePeriod 120 s; `syncfs`. Still hung.
- Key evidence: after logging `ready to accept connections`, PG answered nothing (not even via unix socket); ~100 backends stuck in `authentication` state in `ep_poll`; 3 `io worker` processes asleep; recovery always waited **exactly 5 min** (= checkpoint_timeout) between `redo done` and the end-of-recovery checkpoint; authentication_timeout (60 s) never fired. Signal masks were normal (SIGURG blocked for signalfd, not ignored).
- Conclusion: inter-process latch wake-ups (signalfd/epoll) not working → PG 18's default `io_method = worker` blocks forever. **Fix: `io_method = sync`** (+ `checkpoint_timeout = 60s`). DB came up in ~2 min, all apps healthy.
- Suspected underlying cause: kernel 7.0.0-42 (everything started after first booting it). Not yet verified.

## 2026-10-30 — documentation, time zone, secrets move
- Added `CLAUDE.md` + `.claude/skills/` (this documentation) and rewrote the README.
- Server time zone changed from `Etc/UTC` to `Europe/Madrid` (`timedatectl`); NTP was already synced. Containers and Kubernetes still log in UTC (PostgreSQL logs say `GMT`).
- Moved fest-descans SealedSecrets to fest-page (decision D15) with zero downtime: removed the `fest-descans-secrets` Application (no finalizer → secrets stayed), then the `fest-descans-api` app adopted both SealedSecrets; Secrets kept their original age.
- Repo layout: `platform/` and `apps/` merged into `components/` (decision D16); Applications labelled `homelab/tier`. Paths changed only, no resources redeployed.
- Parent app `fest-descans` now groups `fest-descans-{web,admin,api}` (decision D17); ApplicationSet hardened with `preserveResourcesOnDeletion`.
