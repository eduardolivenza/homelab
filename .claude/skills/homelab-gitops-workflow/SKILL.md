---
name: homelab-gitops-workflow
description: How to change anything on the homelab cluster through this repo — layout, adding an app, pushing, forcing an ArgoCD refresh, verifying, and ArgoCD/StatefulSet gotchas. Use before proposing any cluster change.
---

# GitOps workflow

## Repo layout

```
CLAUDE.md                     entry point for Claude
bootstrap/root-app.yaml       the only manifest applied by hand (app-of-apps root)
argocd-apps/                  one Application (or ApplicationSet) per component; synced by "root"
  argocd.yaml                 → platform/argocd          (prune: false)
  sealed-secrets.yaml         → Helm chart sealed-secrets (kube-system)
  cloudflared.yaml            → platform/cloudflared     (ns cloudflared)
  fest-descans.yaml           → ApplicationSet web/admin/api from fest-page repo + app fest-descans-secrets (prune: false)
  home-assistant.yaml         → pajikos chart + values from apps/home-assistant/values.yaml ($values multi-source)
platform/argocd/              kustomization: upstream install.yaml (pinned) + patches
platform/cloudflared/         local Helm chart; values.yaml has the tunnel routes; templates/sealed-credentials.yaml
apps/home-assistant/values.yaml
apps/fest-descans/secrets/    SealedSecrets for namespace fest-descans
host/k3s/config.yaml          copy of /etc/rancher/k3s/config.yaml (applied by hand)
renovate.json                 Renovate config (whitelisted in .gitignore)
.gitignore                    ignores *.json, *-secret.yaml, *.unsealed.yaml, .env — never commit plaintext secrets
```

The `root` app has `prune: false`: deleting a file in `argocd-apps/` does **not** delete the Application. Delete it by hand (`kubectl delete application <name> -n argocd`) after removing the file.

## Standard change loop (what Edu runs on the server)

```bash
cd ~/repositories/homelab && git pull
# edit files (prefer yq for YAML: yq -i '.image.tag = "x"' file.yaml)
git diff                                   # review before committing
git commit -am "<what and why>" && git push
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
sleep 60
kubectl get applications -n argocd         # expect Synced / Healthy
```

- ArgoCD polls every ~3 min; the annotation forces it now. There is no GitHub webhook.
- Render locally before pushing when touching kustomize/Helm: `kubectl kustomize platform/argocd`, `helm template x platform/cloudflared -n cloudflared`.
- For changes in fest-page (`~/repositories/fest-page`) use `git pull --rebase` first: its CI pushes image-tag commits to `main` all the time.
- Commit messages: imperative, say what and why (`home-assistant: add startupProbe for slow disk`).
- Claude cannot push. Hand Edu a single, reviewable block per step and tell him the expected output.

## Verify

```bash
kubectl get applications -n argocd
kubectl get application <app> -n argocd -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl get application <app> -n argocd -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Gotchas

1. **StatefulSets don't replace a broken pod.** If a StatefulSet pod is crash-looping or never Ready, a spec change won't roll it. After ArgoCD syncs, check the new spec is on the STS, then `kubectl delete pod <name>-0 -n <ns>`. Seen with HA and PostgreSQL. Data is on the PVC, deleting the pod is safe; **never delete the PVC or the STS**.
2. **Manual edits are reverted** by `selfHeal`. Temporary experiments must go through Git too.
3. **`OutOfSync` with `prune: false`** usually means a resource exists in the cluster that was removed from Git — delete it by hand once.
4. **`Sync: Unknown` + `ComparisonError ... authentication required`**: a stale repo credential in ArgoCD. Public repos need none: `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository`, check `.data.url`, delete the stale one.
5. **Adopting existing resources**: an Application in Git with the same name as an existing one is adopted in place (how `home-assistant` and `fest-descans` were migrated).
6. **Order of dependencies**: anything that needs a secret must not be synced before its SealedSecret exists (see `homelab-secrets`).
7. **kubectl timeouts** right after `systemctl restart k3s` or under heavy I/O are normal for 1–2 min on this box; retry.

## Adding a new app (template)

1. Prefer an upstream Helm chart with a **pinned** `targetRevision` and pinned image tag.
2. Create `argocd-apps/<app>.yaml` (copy `home-assistant.yaml` for chart + values-in-repo pattern) and `apps/<app>/values.yaml`.
3. Set resources requests/limits and **generous probes** (startupProbe, `timeoutSeconds` ≥ 5) — the disk is slow.
4. Secrets → SealedSecret in `apps/<app>/secrets/` plus an Application for that path (see `fest-descans-secrets`).
5. Exposure: internet → add a route in `platform/cloudflared/values.yaml` (`http://<svc>.<ns>.svc.cluster.local:<port>`) **and** a DNS CNAME `<name>` → `96ed517e-9c76-4e93-8d7d-220cad16eed3.cfargotunnel.com` (proxied) in Cloudflare; consider Cloudflare Access. LAN only → NodePort (30000–32767) or hostNetwork.
6. Check RAM before adding anything: `free -h`, `kubectl top pods -A --sort-by=memory`.

## Useful tools

- `k9s` (installed from GitHub releases into `/usr/local/bin`): `:pods`, `l` logs, `d` describe, `:secrets` + `x` to decode.
- ArgoCD UI: https://192.168.68.53:30443 (user `admin`).
