---
name: homelab-disaster-recovery
description: Backups, safe reboot, kernel rollback and full rebuild of the homelab server from zero using this repo. Use before risky maintenance, when the laptop/disk dies, or when moving to new hardware (e.g. the planned SSD).
---

# Backups and disaster recovery

## What must be backed up (Git does not have it)

| Item | Where | How | Status (2026-10-30) |
|---|---|---|---|
| Sealed Secrets key | `kube-system` secrets labelled `sealedsecrets.bitnami.com/sealed-secrets-key` | `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/sealed-secrets-key.backup.yaml` → copy to password manager | Taken 2026-10-28 on server; off-server copy not confirmed |
| fest-descans DB | PVC `data-fest-descans-api-postgresql-0` | `pg_dump` (see `fest-descans-postgres`) → copy to PC | Not confirmed |
| HA YAML config | PVC `home-assistant-home-assistant-0` | Automatic: nightly CronJob `ha-config-backup` → private repo `eduardolivenza/home-assistant` (see below) | Since 2026-10-31 |
| HA full (`.storage`, history, integrations) | same PVC | HA UI → Settings → System → Backups → download / backup agent | No regular backups yet |
| HA recordings | host `/home/edu/ha-recordings` (~500 MB) | optional | none |
| Cloudflare tunnel creds | sealed in Git | covered by the key backup | — |
| Server's GitHub SSH key | `~/.ssh` | regenerate if lost, add to GitHub account | — |

Copy from the server to Edu's Windows PC (PowerShell):
`scp edu@192.168.68.53:~/<file> C:\Users\EduardOlivenzaSole\Claude\Projects\LocalServer\`

Raw volume copy (only while the app is stopped): PVCs live under `/var/lib/rancher/k3s/storage/pvc-<uid>_<ns>_<pvc>`:
`sudo tar czf ~/pg-backup-$(date +%F).tar.gz -C /var/lib/rancher/k3s/storage $(sudo ls /var/lib/rancher/k3s/storage | grep data-fest-descans-api-postgresql-0)`

## Safe reboot

PostgreSQL does not get a clean shutdown when the node reboots → 1–5 min crash recovery on start. Do:
```bash
kubectl exec -n fest-descans fest-descans-api-postgresql-0 -- pg_ctl -D /bitnami/postgresql/data stop -m fast -t 120
sudo reboot
```
Then wait 5–10 min and run the health check from `homelab-troubleshooting`.

## Home Assistant config mirror (HA → Git)

- CronJob `ha-config-backup` (ns `home-assistant`, 03:17 Europe/Madrid) mounts HA's PVC **read-only**, copies a **whitelist** and pushes to `git@github.com:eduardolivenza/home-assistant.git` (private) when something changed. Commit message: `HA config <date> (HA <version>)`.
- Whitelist (in `components/ha-config-backup/backup.sh`): `configuration.yaml`, `automations.yaml`, `scripts.yaml`, `scenes.yaml`, `customize.yaml`, `groups.yaml`, `.HA_VERSION`, `packages/`, `themes/`, `blueprints/`, `custom_templates/`. Never: `secrets.yaml`, `.storage/`, databases, logs, recordings, `custom_components/` (reinstall from HACS). A `.gitignore` in the repo repeats the exclusions.
- Auth: deploy key with write access on that repo only, in SealedSecret `ha-config-backup-ssh` (`components/ha-config-backup/sealed-ssh-key.yaml`). GitHub's ed25519 host key is pinned in the script.
- Image `alpine:3.22`, installs git/openssh each run (needs internet). Sync is `rm` + `cp -a` per whitelisted item (rsync hung on this host: same never-woken-up symptom as PostgreSQL).
- Run now / debug:
  ```bash
  kubectl create job --from=cronjob/ha-config-backup ha-config-backup-manual -n home-assistant
  kubectl logs -n home-assistant job/ha-config-backup-manual -f     # timestamped steps; Ctrl+C only stops following
  kubectl delete job ha-config-backup-manual -n home-assistant       # only after reading the logs
  ```
  The script fails fast with a clear message if GitHub is unreachable or the deploy key is wrong
  (`ERROR: cannot reach or authenticate`): check the key is on the repo with **Allow write access**.
  Lesson (2026-10-31): never re-run a block that contains `kubeseal` + `shred` — the second run seals
  nothing and overwrites the SealedSecret file with an empty one (fixed with `git revert`).
- Restore a file: take it from the repo and copy it in: `kubectl cp configuration.yaml home-assistant/home-assistant-0:/config/configuration.yaml -c home-assistant`, then restart HA or reload YAML from the UI.
- This is history for YAML, **not** a full backup.

## Kernel rollback (one boot only, to test)

Kernel 7.0.0-42 (first booted 2026-10-28) is suspected for the PostgreSQL hang; 7.0.0-38 is installed.
```bash
journalctl --list-boots --no-pager | tail -6
for b in -3 -2 -1 0; do echo "boot $b: $(journalctl -b $b -k --no-pager 2>/dev/null | grep -m1 -o 'Linux version [^ ]*')"; done
sudo grep -E "menuentry '|submenu '" /boot/grub/grub.cfg | cut -d"'" -f2 | head -10
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub && sudo update-grub
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-38-generic"   # adjust to the listed name
sudo reboot
uname -r
```
Test: does HA start fast? Remove `io_method = sync` temporarily — does PostgreSQL accept connections? If 38 is good, make it default (`sudo grub-set-default "<entry>"`) and `sudo apt-mark hold` the 42 kernel packages until a newer kernel is out; retest then. A normal reboot returns to the default kernel.

## Full rebuild from zero (new disk / new machine)

1. **OS:** Ubuntu Server, hostname `asusold`, user `edu`, OpenSSH, `sudo timedatectl set-timezone Europe/Madrid`. Same LAN IP via the Deco DHCP reservation (192.168.68.53) or update references (HA LAN URL, ArgoCD URL). Laptop: `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`. Create `/home/edu/ha-recordings`.
2. **K3s with the versioned config:**
   ```bash
   git clone https://github.com/eduardolivenza/homelab.git ~/repositories/homelab && cd ~/repositories/homelab
   sudo mkdir -p /etc/rancher/k3s && sudo cp host/k3s/config.yaml /etc/rancher/k3s/config.yaml
   curl -sfL https://get.k3s.io | sh -
   mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $USER: ~/.kube/config
   kubectl get nodes
   ```
3. **ArgoCD** (same manifests ArgoCD will later manage):
   ```bash
   kubectl create namespace argocd
   kubectl apply -k components/argocd --server-side --force-conflicts
   kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
   ```
4. **Sealed Secrets key first, then the controller:**
   ```bash
   kubectl apply -f ~/sealed-secrets-key.backup.yaml          # into kube-system
   kubectl apply -f argocd-apps/sealed-secrets.yaml
   kubectl get pods -n kube-system | grep sealed               # wait Running
   ```
   No key backup? → follow "If the key is lost" in `homelab-secrets` and re-seal before step 5.
5. **Root app:** `kubectl apply -f bootstrap/root-app.yaml`; watch `kubectl get applications -n argocd`.
6. **Data:** fest-descans starts with an empty DB → restore the `pg_dump` (`fest-descans-postgres`). HA starts fresh → restore the HA backup from its onboarding screen ("Restore from backup").
7. **Tools:** kubeseal, yq, k9s; SSH key for GitHub (`~/.ssh/config` alias `github-homelab`), clone fest-page into `~/repositories`.
8. **Cloudflare:** tunnel and DNS records already exist in the account; nothing to do unless a new tunnel was created.
9. Check every hostname and the ArgoCD UI (https://<ip>:30443, password from `argocd-initial-admin-secret`, then change it and delete that secret).
