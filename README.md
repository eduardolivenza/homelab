# homelab

The home server `asusold` (single-node K3s) described as code and deployed by ArgoCD
(app-of-apps). Website code and charts live in [fest-page](https://github.com/eduardolivenza/fest-page);
this repo declares **what** runs.

```
CLAUDE.md                  entry point for AI assistants
.claude/skills/            full documentation: context, decisions, workflows, runbooks
bootstrap/root-app.yaml    the only manifest applied by hand
argocd-apps/               one Application per component (managed by "root")
components/<name>/         everything a component needs; argocd-apps/<name>.yaml deploys it
  argocd/                  ArgoCD managing itself (kustomize + patches)
  cloudflared/             Cloudflare Tunnel (local chart: routes + sealed credentials)
  home-assistant/          Home Assistant chart values
host/k3s/config.yaml       K3s config (copied by hand to /etc/rancher/k3s/)
renovate.json              weekly dependency PRs
```

## Documentation

| Topic | File |
|---|---|
| Architecture, hardware, decisions, history, open items | `.claude/skills/homelab-context/` |
| How to change things (GitOps loop, gotchas) | `.claude/skills/homelab-gitops-workflow/SKILL.md` |
| Secrets (Sealed Secrets) | `.claude/skills/homelab-secrets/SKILL.md` |
| Upgrades and Renovate | `.claude/skills/homelab-upgrades/SKILL.md` |
| Troubleshooting runbook | `.claude/skills/homelab-troubleshooting/SKILL.md` |
| Backups, safe reboot, rebuild from zero | `.claude/skills/homelab-disaster-recovery/SKILL.md` |
| fest-descans PostgreSQL | `.claude/skills/fest-descans-postgres/SKILL.md` |

## Bootstrap order (new cluster)

1. K3s with `host/k3s/config.yaml`.
2. `kubectl apply -k components/argocd --server-side --force-conflicts`.
3. Restore the Sealed Secrets key backup, then `kubectl apply -f argocd-apps/sealed-secrets.yaml`.
4. `kubectl apply -f bootstrap/root-app.yaml`.

Never apply the root app before the sealed-secrets controller can decrypt the secrets.
Details: `homelab-disaster-recovery`.
