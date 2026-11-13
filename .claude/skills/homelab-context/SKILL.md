---
name: homelab-context
description: Big-picture context of Edu's homelab (K3s server asusold) — hardware, network, architecture, components, decisions and tradeoffs, history and open items. Use at the start of any session about this repo or the server.
---

# Homelab context

State as of 2026-10-30 (partial updates up to 2026-11-13). Decisions with full rationale: `references/decisions.md`.
Chronology of what was done and why: `references/history.md`.

## Owner and way of working

- Owner: Edu (Eudald), Sant Cugat (Barcelona). DevOps background. Writes Spanish/English.
- Claude has **no direct access** to the server: Edu runs commands on the server via SSH and pastes
  output. Claude **can commit and push** the homelab repo from Edu's PC clone (WSL) when asked. The server pushes to GitHub with an SSH key added to Edu's
  GitHub account (SSH host alias `github-homelab` in `~/.ssh/config`, used for both repos).
- Local clones on the server: `~/repositories/homelab`, `~/repositories/fest-page`.

## Hardware and OS (the main constraint)

| Item | Value |
|---|---|
| Host | `asusold`, old laptop, Ubuntu Server 26.04 |
| CPU | 8 cores |
| RAM | **3.2 GB** usable (2 × 2 GB DDR3 SO-DIMM, both slots full; board reports max 16 GB, 8 GB is the safe upgrade) + zram 1.6 GB (prio 5, used first) + `/swap.img` 3.7 GB. Typical use ~2.5 GB. Tuning since 2026-11-13: `vm.swappiness=150`, `vm.page-cluster=0`, journald capped at 200 MB (files in `host/`). |
| Disk | **Seagate ST9640320AS, 5400 rpm HDD**, 596 GB, LVM root LV only **98 GB, 68 % used** (2026-11-12; VG probably has free space to grow it, check `sudo vgs`) |
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
| `github.com/eduardolivenza/homelab` (this) | public | Everything deployed on the cluster: ArgoCD apps (`argocd-apps/`), component configs (`components/`), platform sealed secrets (cloudflared), K3s host config, Renovate config |
| `github.com/eduardolivenza/home-assistant` | **private** | Nightly mirror of HA's YAML config (written by the `ha-config-backup` CronJob; never edit by hand expecting HA to pick it up) |
| `github.com/eduardolivenza/fest-page` | public | The fest-descans website monorepo (Next.js web + admin on Node 26; **API in Java 25 / Spring Boot** since 2026-11-11 — it was Node/Fastify/Prisma before — with Flyway migrations run by the app on startup), its Dockerfiles, GitHub Actions CI, Helm charts `helm/{web,admin,api}` with this environment's values and its own SealedSecrets |

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
| `argocd` | ArgoCD v3.5.x (server, repo-server, application-controller, applicationset-controller, redis). Dex and notifications removed. | `argocd-apps/argocd.yaml` → `components/argocd` (kustomize over upstream install.yaml) |
| `kube-system` | K3s core (coredns, local-path-provisioner, metrics-server) + sealed-secrets-controller | K3s / `argocd-apps/sealed-secrets.yaml` |
| `cloudflared` | Tunnel connector | `components/cloudflared` (local Helm chart) |
| `fest-descans` | web, admin, api (Java/Spring Boot, 512Mi limit, ~270 MB RSS: the largest app after HA), PostgreSQL (official `postgres:18` StatefulSet `fest-descans-api-db` in the api chart) | parent app `fest-descans` (`argocd-apps/fest-descans.yaml`) → ApplicationSet `components/fest-descans/` → apps `fest-descans-{web,admin,api}` from fest-page `helm/<app>`; its SealedSecrets are in fest-page `helm/api/templates/` |
| `home-assistant` | Home Assistant StatefulSet (pajikos chart), hostNetwork, PVC 5Gi + hostPath `/home/edu/ha-recordings` | `argocd-apps/home-assistant.yaml` + `components/home-assistant/values.yaml` |
| `home-assistant` (same ns) | CronJob `ha-config-backup`: nightly mirror of HA YAML config to the **private** repo `eduardolivenza/home-assistant` | `argocd-apps/ha-config-backup.yaml` + `components/ha-config-backup/` |

Home Assistant integrations in use (for upgrade risk): custom integrations from the built-in Marketplace
(HACS until 2026.11, when HA absorbed it) — edata (Datadis electricity), localtuya, tuya_local (xZetsubou fork,
thermostat), imou_life (camera, ONVIF/RTSP, person-detection recordings), hisense / hisense_ac_plugin,
Broadlink RM4 Pro.

## Things that live OUTSIDE Git (know them)

- K3s itself and `/etc/rancher/k3s/config.yaml` (a copy is versioned in `host/k3s/config.yaml`, applied by hand).
- Host tuning: `/etc/sysctl.d/99-zram.conf` and `/etc/systemd/journald.conf.d/size.conf` (copies in `host/sysctl/`, `host/journald/`, applied by hand). Docker/containerd system services disabled (2026-11-13).
- The bootstrap `kubectl apply` of ArgoCD and `bootstrap/root-app.yaml`.
- The Sealed Secrets private key (backup in `~/sealed-secrets-key.backup.yaml` on the server; should also be in a password manager).
- Cloudflare: DNS records, the tunnel itself, (future) Access policies. Configured in the dashboard / via `cloudflared tunnel route dns`.
- Data: HA PVC, PostgreSQL PVC, `/home/edu/ha-recordings`.
- Renovate is the Mend-hosted GitHub app (installed on all repos, mode **Interactive**).

## Open items / roadmap (as of 2026-11-02)

Highest value first:
1. Automated nightly `pg_dump` of fest-descans to a location off the server (only manual dumps so far; last 2026-11-02).
2. Fix the AppArmor signal denial on the host (root cause of the PG hangs, likely also rsync), then remove `appArmorProfile: Unconfined` from fest-page; check which other containers are hit (`fest-descans-postgres`).
3. fest-descans DB cleanup: delete old Bitnami PVC `data-fest-descans-api-postgresql-0` after 2026-11-05; remove `io_method: sync` after 2026-11-09.
4. Hardware: SSD (+ RAM).
5. fest-page infra review fixes still open (2026-11-13): probe `timeoutSeconds` on web/admin (the Java api already has generous probes), DB backup CronJob, web SSR calls the public API URL instead of in-cluster, outdated secret comments in values.yaml. Done: Node upgrade (26), dead Ingresses removed, migrate initContainer gone (Java rewrite).
6. ~~HA full backups off the laptop; recordings retention~~ done 2026-11-12 (Google Drive daily backups; `ha-recordings-cleanup` 14 days). Pending: rotate the HA backup encryption key (it was pasted into a Claude chat) and delete old manual backups in `/config/backups` (~590 MB).
6b. Root LV is 98 GB of the 596 GB disk and 68 % full: check `sudo vgs; sudo lvs` and grow it online (`lvextend -r`) if the VG has free space.
7. Check disk health with `smartctl` (never done).
8. ~~Disable Docker on the host~~ done 2026-11-13 (no containers; `docker.socket docker containerd` disabled). Could also be uninstalled.
8b. Local voice for HA (`ha-voice`: Piper TTS + Speech-to-Phrase STT as Wyoming pods, ~270 MB) was added and **removed the same day (2026-11-13)**: the box thrashed (`wa` 57–75 %, 10+ processes in D state, even with Docker off). Voice now = Siri on iPhone (Companion app Assist shortcut; Siri does the STT, no server cost). To bring it back after a RAM upgrade: `git revert` the removal commit (manifests in commit b516415) and seal a NEW HA long-lived token (the old one was revoked). The same day the real cause of the chronic I/O wait (60–95 % since boot) was found: page-cache thrashing (programs' code evicted and re-read from the HDD) plus a 1.9 GB journal. Fixed with the zram sysctls + journald cap → `wa` 1–4 %. Next: RAM upgrade to 2 × 4 GB DDR3 SO-DIMM.
9. Cloudflare as code (OpenTofu) + Cloudflare Access in front of HA; host/K3s as code (Ansible).
10. Change the fest admin password if the seed default (`admin123!`, public in fest-page) is still valid.
