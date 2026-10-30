# homelab — context for Claude

This repo describes Edu's home server **`asusold`** (single-node K3s) as code. ArgoCD deploys
everything in it. This file is the entry point; the detailed knowledge lives in the project skills
under `.claude/skills/`. Read the relevant skill before acting.

| Skill | Use it when |
|---|---|
| `homelab-context` | You need the big picture: hardware, network, architecture, every decision and why, history, open items. **Start here in a new session.** |
| `homelab-gitops-workflow` | Making any change to the cluster: repo layout, how changes flow, how to verify, ArgoCD gotchas. |
| `homelab-secrets` | Creating, reading, rotating or recovering secrets (Sealed Secrets). |
| `homelab-upgrades` | Renovate PRs and upgrading HA, cloudflared, ArgoCD, charts, K3s, the kernel. |
| `homelab-troubleshooting` | Something is slow, crashlooping, not ready, unreachable. Symptom → diagnosis → fix runbook. |
| `homelab-disaster-recovery` | Backups, safe reboots, rebuilding the server from zero, kernel rollback. |
| `fest-descans-postgres` | Anything about the fest-descans PostgreSQL database (it has a non-obvious workaround). |

## Ground rules (learned the hard way)

- **Git is the source of truth.** Never fix things with `kubectl edit/patch/scale` on resources ArgoCD manages: `selfHeal` reverts them. Change the repo, push, refresh.
- **The server is weak:** 3.2 GB RAM, 5400 rpm HDD. Every new component costs RAM, and slow disk I/O is the root cause of most incidents. Probes must be generous.
- **Claude has no direct access to the server or to GitHub push.** Edu runs commands over SSH on the server (`edu@192.168.68.53`) and pastes the output. Give him copy-pasteable command blocks, one step at a time, with what the expected output looks like.
- **Pin every image/chart version.** `latest`/`stable` caused two incidents. Renovate proposes upgrades.
- **Protect data first.** Back up (HA backup, `pg_dump`) before touching stateful apps.
- Edu writes in Spanish or English; answer in the language he uses.

Last full update of this documentation: 2026-10-30.
