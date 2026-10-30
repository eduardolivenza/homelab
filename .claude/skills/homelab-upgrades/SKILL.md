---
name: homelab-upgrades
description: How upgrades work on the homelab — Renovate PRs, merge order, and per-component procedures for Home Assistant, cloudflared, ArgoCD, Sealed Secrets, charts, K3s and the host kernel. Use when a Renovate PR is open or something needs a version bump.
---

# Upgrades

## Renovate

- Mend-hosted GitHub app, installed on all of Edu's repos, account mode **Interactive** (it was Silent at first: no issue/PRs appeared). Logs and a "run now" button at https://developer.mend.io.
- Config: `renovate.json`. Runs **Saturday before 10:00 Europe/Madrid**, max 5 open PRs, never automerges.
- The **Dependency Dashboard** issue lists everything; tick a checkbox under "Awaiting Schedule" to get a PR immediately.
- What it tracks (verified with a dry run):

| Dependency | File | Manager |
|---|---|---|
| HA image `ghcr.io/home-assistant/home-assistant` | `components/home-assistant/values.yaml` | helm-values (one PR per monthly release) |
| HA chart `home-assistant` (pajikos) | `argocd-apps/home-assistant.yaml` | argocd |
| `cloudflare/cloudflared` | `components/cloudflared/values.yaml` | helm-values |
| `sealed-secrets` chart | `argocd-apps/sealed-secrets.yaml` | argocd |
| ArgoCD (`argoproj/argo-cd` GitHub releases) | `components/argocd/kustomization.yaml` | regex custom manager |

- After merging a PR on GitHub: `git pull` the server clone, force a refresh, verify (see `homelab-gitops-workflow`).
- Renovate is not configured on fest-page yet (an onboarding PR may be open there; tune it before merging — a pnpm/Next.js monorepo produces many PRs).

## Merge order and rules

1. Security fixes first (e.g. cloudflared).
2. One PR at a time; wait until everything is `Synced/Healthy` before the next. Renovate rebases the rest.
3. Charts before app versions when both are pending (isolates the cause of a failure).
4. Major versions (ArgoCD v3 → v4, chart majors) only after reading upgrade notes, on a quiet day.

## Home Assistant

- HA **cannot be downgraded** (DB/storage migrations). Before every upgrade: HA UI → Settings → System → Backups → create + **download** off the laptop.
- Update HACS custom integrations first (localtuya, tuya_local, imou_life, hisense) — old custom integrations are the usual breakage.
- One monthly release at a time (2026.11.x, then 2026.12.x…), take the latest patch of each month. Read https://www.home-assistant.io/blog/ breaking changes.
- After merge:
  ```bash
  kubectl annotate application home-assistant -n argocd argocd.argoproj.io/refresh=hard --overwrite
  kubectl get pods -n home-assistant -w      # up to ~5 min; delete the pod if it keeps the old image
  kubectl logs -n home-assistant home-assistant-0 -c home-assistant --tail=200 | grep -E 'ERROR|Setup failed'
  ```
  Check http://192.168.68.53:8123, https://homeassistant.festdescans.com and devices (thermostat, camera, Broadlink).
- If external access returns **400 Bad Request**: HA no longer trusts the proxy. Since 2026.8 the `http:` YAML (`use_x_forwarded_for`, `trusted_proxies`) moved to `.storage/http` (YAML support removed in 2027.2). Fix the trusted proxies there/in the UI. Rollback = restore the backup (not `git revert` alone).
- Current: HA 2026.10.4, chart 0.3.89. The chart has an `httpYamlSupported` helper that only matters when the chart's ingress is enabled (it isn't).

## cloudflared

2 replicas + readiness on `/ready` → rolling upgrade without downtime. After merge:
```bash
kubectl rollout status deployment cloudflared -n cloudflared --timeout=5m
kubectl get pods -n cloudflared -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"  ready="}{.status.containerStatuses[0].ready}{"\n"}{end}'
```
Cloudflare dashboard → Networking → Tunnels should show the new connector version and Healthy. If `ImagePullBackOff`, the tag isn't on Docker Hub yet.

## ArgoCD

- Version in `components/argocd/kustomization.yaml` (`.../argo-cd/vX.Y.Z/manifests/install.yaml`). Minor upgrades via Renovate PR are fine (3.4.4 → 3.5.6 went smoothly).
- After merge check: `kubectl get pods -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'`.
- If ArgoCD breaks itself: `kubectl apply -k components/argocd --server-side --force-conflicts` from the server clone.
- The kustomize patches (Dex/notifications deletion, NodePort) depend on upstream resource names/port order; re-render with `kubectl kustomize components/argocd` on majors.

## Sealed Secrets controller

Chart upgrades are low risk; keys persist in `kube-system`. Keep `kubeseal` CLI at the same app version. Re-take the key backup after upgrading.

## fest-page apps

Image tags are bumped by fest-page CI, not Renovate. PostgreSQL is special — see `fest-descans-postgres` (image pinned by digest; don't switch to `latest`).

## K3s

Installed with the get.k3s.io script, not managed by Git. Upgrade by re-running the installer with a pinned channel/version (`curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=vX.Y.Z+k3s1 sh -`). Config in `/etc/rancher/k3s/config.yaml` is preserved. Expect 1–2 min of kubectl timeouts.

## Host OS / kernel

Ubuntu unattended-upgrades installs kernels automatically; they take effect on the next reboot, often days later — correlate incidents with `journalctl --list-boots` and `/var/log/apt/history.log`. Kernel 7.0.0-42 is a suspect for the PostgreSQL hang (see `homelab-troubleshooting`). Rollback procedure in `homelab-disaster-recovery`.
