---
name: homelab-context
description: Big-picture context of Edu's homelab (K3s server asusold) — hardware, network, architecture, components, decisions and tradeoffs, history and open items. Use at the start of any session about this repo or the server.
---

# Homelab context

State as of 2026-10-30. Decisions with full rationale: `references/decisions.md`.
Chronology of what was done and why: `references/history.md`.

## Owner and way of working

- Owner: Edu (Eudald), Sant Cugat (Barcelona). DevOps background. Writes Spanish/English.
- Claude has **no direct access** to the server nor push rights on GitHub. Edu runs commands on the
  server via SSH and pastes output. The server pushes to GitHub with an SSH key added to Edu's
  GitHub account (SSH host alias `github-homelab` in `~/.ssh/config`, used for both repos).
- Local clones on the server: `~/repositories/homelab`, `~/repositories/fest-page`.

## Hardware and OS (the main constraint)

| Item | Value |
|---|---|
| Host | `asusold`, old laptop, Ubuntu Server 26.04 |
| CPU | 8 cores |
| RAM | **3.2 GB** + 5.4 GB swap (+ zram). Typical use ~2.2 GB, ~1 GB available. |
| Disk | **Seagate ST9640320AS, 5400 rpm HDD**, 596 GB, LVM root, ~33 % used |
| Kernel | 7.0.0-42-generic (first booted 2026-10-28). 7.0.0-38 still installed. |
| Time zone | `Europe/Madrid` on the host (since 2026-10-30); containers and Kubernetes log in UTC |
| Network | Wi-Fi/Ethernet on TP-Link Deco mesh, LAN `192.168.68.0/24`, server **192.168.68.53** (DHCP reservation) |
| ISP | Lowi (Vodafone MVNO) → **CGNAT**, no inbound ports from the internet |
| Extra | Docker (docker-ce + containerd.io) is also installed on the host, probably unused |

Note: `home-server-guide.md` (older planning doc, outside this repo) assumed 16 GB RAM; reality is 3.2 GB.

Consequences: when memory runs out the box swaps to the HDD, I/O wait goes to 30–50 %, the kubelet
stalls (node flaps `NotReady`) and liveness probes kill slow pods. Recommended hardware fix: SATA SSD
(+ RAM upgrade if the laptop supports it). Not done yet.

## Repositories

| Repo | Visibility | Contains |
|---|---|---|
| `github.com/eduardolivenza/homelab` (this) | public | Everything deployed on the cluster: ArgoCD apps, platform components, HA values, platform sealed secrets (cloudflared), K3s host config, Renovate config |
| `github.com/eduardolivenza/fest-page` | public | The fest-descans website monorepo (Next.js web + admin, Fastify API, Prisma), its Dockerfiles, GitHub Actions CI, Helm charts `helm/{web,admin,api}` with this environment's values and its own SealedSecrets |

fest-page CI builds images to `ghcr.io/eduardolivenza/festpage/{web,admin,api}` and commits the new
tag into `helm/<app>/values.yaml` (`ci: update ... [skip ci]`). ArgoCD here deploys those charts.

## Architecture

```
Internet → Cloudflare (festdescans.com zone) → Cloudflare Tunnel 96ed517e-…
        → cloudflared pods (ns cloudflared, 2 replicas) → ClusterIP Services directly
              festdescans.com              → fest-descans-web:3000
              admin.festdescans.com        → fest-descans-admin:3002
              api.festdescans.com          → fest-descans-api:3001
              homeassistant.festdescans.com→ home-assistant.home-assistant:8123

LAN only:  Home Assistant  http://192.168.68.53:8123   (hostNetwork)
           ArgoCD UI       https://192.168.68.53:30443 (NodePort, self-signed cert)
```

There is **no ingress controller**: Traefik (K3s built-in) is disabled. Old `Ingress` objects in the
fest-page charts are inert leftovers.

## What runs (namespaces)

| Namespace | What | Managed by |
|---|---|---|
| `argocd` | ArgoCD v3.5.x (server, repo-server, application-controller, applicationset-controller, redis). Dex and notifications removed. | `argocd-apps/argocd.yaml` → `platform/argocd` (kustomize over upstream install.yaml) |
| `kube-system` | K3s core (coredns, local-path-provisioner, metrics-server) + sealed-secrets-controller | K3s / `argocd-apps/sealed-secrets.yaml` |
| `cloudflared` | Tunnel connector | `platform/cloudflared` (local Helm chart) |
| `fest-descans` | web, admin, api (+ migrate initContainer), PostgreSQL (Bitnami subchart of the api chart) | `argocd-apps/fest-descans.yaml` (ApplicationSet → fest-page `helm/{web,admin,api}`); its SealedSecrets are in fest-page `helm/api/templates/` |
| `home-assistant` | Home Assistant StatefulSet (pajikos chart), hostNetwork, PVC 5Gi + hostPath `/home/edu/ha-recordings` | `argocd-apps/home-assistant.yaml` + `apps/home-assistant/values.yaml` |

Home Assistant integrations in use (for upgrade risk): HACS, localtuya, tuya_local (xZetsubou fork,
thermostat), imou_life (camera, ONVIF/RTSP, person-detection recordings), hisense / hisense_ac_plugin,
Broadlink RM4 Pro.

## Things that live OUTSIDE Git (know them)

- K3s itself and `/etc/rancher/k3s/config.yaml` (a copy is versioned in `host/k3s/config.yaml`, applied by hand).
- The bootstrap `kubectl apply` of ArgoCD and `bootstrap/root-app.yaml`.
- The Sealed Secrets private key (backup in `~/sealed-secrets-key.backup.yaml` on the server; should also be in a password manager).
- Cloudflare: DNS records, the tunnel itself, (future) Access policies. Configured in the dashboard / via `cloudflared tunnel route dns`.
- Data: HA PVC, PostgreSQL PVC, `/home/edu/ha-recordings`.
- Renovate is the Mend-hosted GitHub app (installed on all repos, mode **Interactive**).

## Open items / roadmap (as of 2026-10-30)

Highest value first:
1. Confirm a `pg_dump` of fest-descans exists off the server (see `fest-descans-postgres`).
2. Migrate PostgreSQL from Bitnami image to official `postgres:18` (plan in `fest-descans-postgres`).
3. Test kernel 7.0.0-38 vs 7.0.0-42 (suspected cause of PG/HA hangs; see `homelab-troubleshooting`).
4. Hardware: SSD (+ RAM).
5. fest-page infra review fixes: probe `timeoutSeconds` (default 1 s) on web/admin/api, DB backup CronJob, Node 20 → 22/24, web SSR calls the public API URL instead of in-cluster, remove dead Ingresses, migrate initContainer retries forever, outdated secret comments in values.yaml.
6. HA backups off the laptop; recordings retention CronJob (days to keep not decided).
7. Check disk health with `smartctl` (never done).
8. Disable Docker on the host if unused (frees RAM).
9. Cloudflare as code (OpenTofu) + Cloudflare Access in front of HA; host/K3s as code (Ansible).
10. Change the fest admin password if the seed default (`admin123!`, public in fest-page) is still valid.
