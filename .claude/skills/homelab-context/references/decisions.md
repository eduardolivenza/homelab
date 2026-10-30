# Decisions and tradeoffs

Each entry: decision → why → tradeoff / what we gave up → revisit when.

## D1. GitOps with ArgoCD, app-of-apps
- **Decision:** one root Application (`bootstrap/root-app.yaml`) syncs `argocd-apps/`, one file per component.
- **Why:** ArgoCD was already running and deploying fest-page; Edu wanted *everything* as code, not just the web.
- **Tradeoff:** ArgoCD costs ~350 MB RAM on a 3.2 GB box. Flux would be lighter but meant re-learning and migrating.
- **Revisit:** if RAM stays the bottleneck after an SSD/RAM upgrade isn't possible.

## D2. Separate `homelab` repo, app repo keeps only app charts
- **Decision:** shared infra (ArgoCD, cloudflared, secrets, HA) moved out of fest-page into this repo. The ApplicationSet that deploys fest-page charts lives here.
- **Why:** before, the tunnel (and HA's route) lived in the website repo — deleting/changing that repo would cut access to HA.
- **Tradeoff:** two repos to keep consistent; fest-page charts are referenced at `HEAD` (CI pushes tags there).

## D3. Repo is public
- **Why:** ArgoCD reads it without credentials (one less secret to bootstrap). Secrets are encrypted.
- **Tradeoff:** exposes domain names, tunnel ID, internal paths (`/home/edu/ha-recordings`), LAN IP. Accepted.
- Related: ArgoCD had a stale token for the public fest-page repo that broke syncs (`Unknown`); it was deleted. Public repos need no repo credentials.

## D4. Sealed Secrets for secrets
- **Decision:** bitnami-labs Sealed Secrets controller (`kube-system`, release name `sealed-secrets-controller` so `kubeseal` finds it by default).
- **Why:** tiny footprint, no external KMS, works offline, encrypted YAML in Git.
- **Alternatives rejected:** SOPS+age (needs ArgoCD plugin), External Secrets/Vault (too heavy for 3.2 GB).
- **Tradeoff:** the controller's private key is a single point of failure → must be backed up outside Git. Sealed secrets are bound to name+namespace.

## D5. cloudflared in-cluster, routing straight to Services; Traefik disabled
- **Why:** CGNAT means no inbound ports, the tunnel is outbound-only and free. Routing directly to ClusterIP Services makes an ingress controller unnecessary; disabling Traefik saved ~70 MB + svclb pod.
- **Tradeoff:** no host/path routing inside the cluster, no `*.local` hostnames; LAN access uses hostNetwork (HA) or NodePort (ArgoCD). cloudflared runs 2 replicas so rolling upgrades don't cut traffic.
- Tunnel credentials are a SealedSecret inside the cloudflared chart (`templates/sealed-credentials.yaml`); the route list is `components/cloudflared/values.yaml`. DNS records are still manual (Cloudflare dashboard / `cloudflared tunnel route dns`).

## D6. ArgoCD manages itself
- **Decision:** `components/argocd/kustomization.yaml` = upstream `install.yaml` at a pinned version + patches. `prune: false` on the `argocd` and `root` apps.
- **Why:** upgrades via Git/Renovate; no forgotten manual installs.
- **Tradeoff:** a bad commit can break ArgoCD itself (recover with `kubectl apply -k components/argocd --server-side`). With `prune: false`, removed resources must be deleted by hand once (was needed for Dex/notifications).
- Patches: Dex and notifications controller deleted (RAM; only `admin` login is used), `argocd-server` Service as NodePort 30080/30443.

## D7. ArgoCD UI on LAN-only NodePort (not through the tunnel)
- **Why:** quick, zero extra RAM, unreachable from the internet thanks to CGNAT + no tunnel route.
- **Deferred alternative:** `argocd.festdescans.com` through the tunnel protected by Cloudflare Access (needs `server.insecure`, a route, a DNS record and an Access policy).

## D8. Home Assistant: pajikos Helm chart, hostNetwork, pinned image
- **Why:** it was already deployed with that chart (Application created by hand); adopting it in Git meant zero redeploy. hostNetwork is required for device discovery / Broadlink / Tuya local.
- Values copied 1:1 from the old hand-made Application, then: image pinned (was `stable`), startupProbe (5 min) + tolerant liveness (≈5 min), ingress disabled.
- `configuration.forceInit: true` merges chart config into `/config/configuration.yaml` on each start (keeps backups).
- **Tradeoff:** UI-made config (`.storage`) is not in Git → needs HA backups.

## D9. Renovate (Mend app), weekly, never automerge
- Schedule Saturday before 10:00 Europe/Madrid, dashboard issue, max 5 PRs. HA image: one PR per monthly release (`separateMultipleMinor`). ArgoCD install version tracked with a regex manager. `git-tags` (ArgoCD apps at HEAD) disabled.
- **Gotchas:** the Mend app was in *Silent* mode until switched to *Interactive*. `.gitignore` ignores `*.json` (protects tunnel credentials) so `renovate.json` is whitelisted with `!renovate.json`.

## D10. Probes tuned for a slow HDD
- HA and PostgreSQL got startupProbes and long liveness tolerances. Rationale: kills during slow starts caused crash loops that made everything worse (each restart re-reads from the HDD).
- **Tradeoff:** genuinely hung processes are detected later (minutes, not seconds).

## D11. RAM diet
- Removed Traefik, ArgoCD Dex and notifications. Kept metrics-server (needed for `kubectl top`). Candidate next: Docker on the host.

## D12. fest-descans PostgreSQL: keep Bitnami for now, with workarounds
- Image pinned by digest (PG 18.4) instead of `latest`; `io_method = sync`, `checkpoint_timeout = 60s`, `recovery_init_sync_method = syncfs`, startupProbe up to 30 min, `terminationGracePeriodSeconds: 120`.
- **Why:** see `fest-descans-postgres`. Bitnami stopped publishing free versioned images (2025) and its chart (13.4.4, made for PG 16) is mismatched with the PG 18 image → planned migration to official `postgres:18`.

## D13. Server pushes to GitHub with an account-wide SSH key
- Started with per-repo deploy keys; Edu chose to add the server key to his GitHub account instead.
- **Tradeoff:** the server can write to all of Edu's repos. Keep `~/.ssh` private; remove the key if the server is retired.

## D15. App secrets live with the app (fest-page), not in homelab
- **Decision (2026-10-30):** `fest-descans-api` and `ghcr-credentials` SealedSecrets moved to fest-page `helm/api/templates/`; `global.imagePullSecrets` moved from the ApplicationSet parameter to each chart's values. The `fest-descans-secrets` Application was removed.
- **Why:** the chart defines the secret's keys (one PR for both); fest-page already holds this environment's deployment config (domains, image tags, PG tuning); secrets deploy with the app, no separate app/ordering.
- **Tradeoff:** fest-page is tied to this cluster's sealing key (it already was, in practice); secrets are now spread over two repos (homelab keeps platform ones: cloudflared).
- `ghcr-credentials` kept (images stay private) rather than making ghcr packages public; it sits in the api chart but serves web/admin/api.

## D16. One `components/` folder instead of `platform/` + `apps/`
- **Decision (2026-10-30):** `platform/argocd`, `platform/cloudflared` and `apps/home-assistant` moved to `components/<name>/`. Rule: `argocd-apps/<x>.yaml` deploys `components/<x>/`. The infra/app distinction is kept as an Application label `homelab/tier: platform|app`.
- **Why:** after D15 `apps/` held only HA; folder names didn't match content (full chart vs only values); with ~5 components the extra level added no information.
- **Tradeoff:** with many components, a split by tier (or by sync wave) could be useful again; revisit then. Option rejected: putting each Application inside its component folder (needs a recursive, filtered root app).

## D14. Host config versioned but applied by hand
- `host/k3s/config.yaml` mirrors `/etc/rancher/k3s/config.yaml` (currently only `disable: [traefik]`). Copy + `sudo systemctl restart k3s` to apply. Ansible planned.
