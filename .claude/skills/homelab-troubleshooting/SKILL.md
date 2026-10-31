---
name: homelab-troubleshooting
description: Runbook for homelab incidents — slow server, swap thrashing, pods killed by probes, StatefulSets not rolling, PostgreSQL or Home Assistant not starting, ArgoCD out of sync, tunnel down. Symptom → diagnostic commands → fix. Use when anything misbehaves.
---

# Troubleshooting runbook

Always start with the 30-second health check, then jump to the matching symptom.

```bash
uptime; free -h; vmstat 2 3
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl get applications -n argocd
```
Healthy baseline (2026-10-29 after fixes): load ~1, `wa` < 12 %, swap used ~150 MB, `available` ~1 GB.
Warning signs: load > 8, `wa` > 20 % sustained, `si/so` in the thousands, `available` < 400 MB, node `NotReady`.

## 1. Whole server slow, pods restarting, node flaps NotReady

**Cause seen:** RAM exhausted → swapping to the 5400 rpm HDD → I/O wait 30–50 % → kubelet and probes time out.
```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL           # ROTA=1 → HDD
vmstat 2 6                                  # wa, si, so, b
ps -eo state,pid,comm | awk '$1=="D"'       # processes blocked on I/O
ps -eo rss,comm --sort=-rss | head -12
kubectl top pods -A --sort-by=memory | head -12
sudo dmesg -T | grep -iE 'oom|killed process|I/O error|hung task' | tail
```
**Fix:** free RAM (already removed Traefik, ArgoCD Dex/notifications; next candidate: `sudo systemctl disable --now docker containerd` if Docker is unused), reboot to clear swap, make probes tolerant. Real fix: SSD (+RAM). Load average high with idle CPU = I/O wait, not CPU.

## 2. Pod killed with exit 137 / "failed liveness probe" / "failed startup probe"

Slow start on the HDD exceeds the probe budget → kill → restart reads everything again → loop.
**Fix in Git:** add `startupProbe` (minutes of budget), liveness `timeoutSeconds` ≥ 10–15 and `failureThreshold` ≥ 10. Defaults (1 s timeout) are too strict here. Then see #3.

## 3. Spec changed in Git, pod still old

StatefulSets do not replace a pod that is crash-looping or not Ready.
```bash
kubectl get sts <sts> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].startupProbe}{"\n"}'   # new spec present?
kubectl get pod <sts>-0 -n <ns> -o jsonpath='{.spec.containers[0].startupProbe}{"\n"}'              # pod still old?
kubectl delete pod <sts>-0 -n <ns>
```

## 4. PostgreSQL (fest-descans) says "ready" but nobody can connect

Full story and settings in `fest-descans-postgres`. Signature:
- `pg_isready` → `no response` even with `-t 20` and via `-h /tmp` (unix socket).
- On the host, `sudo ps -eo pid,stat,wchan:32,etime,args | grep '[p]ostgres'` shows many backends in `authentication` state for minutes, all `S ep_poll`, plus sleeping `io worker` processes.
- Startup always waits exactly `checkpoint_timeout` between `redo done` and `checkpoint starting: end-of-recovery`.

**Fix (applied):** `io_method = sync` in `postgresql.primary.extendedConfiguration` (fest-page `helm/api/values.yaml`), `checkpoint_timeout = 60s`. Then delete the pod.
**Underlying suspicion:** latch wake-ups (signalfd + epoll) not delivered under kernel 7.0.0-42. Same pattern seen with `rsync` in the `ha-config-backup` job (forked processes idle forever after finishing the copy, server idle). If a tool hangs with all processes in `S` and nothing to do, suspect this and avoid multi-process tools or test kernel 7.0.0-38. Test by booting 7.0.0-38 and temporarily removing `io_method = sync` (procedure in `homelab-disaster-recovery`).
Note: `pg_isready` without `-U` returns `no attempt` (exit 3) in the Bitnami container — that is a client-side quirk, not a server problem.

## 5. PostgreSQL crash recovery after a bad shutdown

Logs `database system was not properly shut down; automatic recovery in progress`, `the database system is starting up` repeated. Normal; `invalid record length ... got 0` is just the end of WAL. Give it time (startupProbe allows 30 min). Avoid unclean shutdowns: stop it first (`pg_ctl -D /bitnami/postgresql/data stop -m fast -t 120` inside the pod) before rebooting the server.

## 6. Home Assistant not starting / restarting

```bash
kubectl get pods -n home-assistant
kubectl describe pod home-assistant-0 -n home-assistant | sed -n '/^Events/,$p'
kubectl logs -n home-assistant home-assistant-0 -c setup-config --tail=30
kubectl logs -n home-assistant home-assistant-0 -c home-assistant --tail=80 | grep -vE 'custom integration'
kubectl logs -n home-assistant home-assistant-0 -c home-assistant --previous --tail=80
```
Known causes: liveness kill during slow start (#2/#3), server thrashing (#1), a custom integration broken by an upgrade (check logs for `Setup failed`). `exit 143` = SIGTERM from a probe; `exit 137` = SIGKILL.

## 7. ArgoCD app `Unknown` / `OutOfSync`

- `ComparisonError ... authentication required`: stale repo credential → delete it (`kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository`).
- `... not a valid chart repository ... 404`: wrong chart repo URL (sealed-secrets is `https://bitnami.github.io/sealed-secrets`).
- `OutOfSync` on `argocd`/`root`: `prune: false` → delete the extra resource by hand.
- Stale status after a fix: `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.

## 8. Website or HA unreachable from the internet

```bash
kubectl get pods -n cloudflared
kubectl logs -n cloudflared deploy/cloudflared --tail=30
kubectl get svc -A | grep -E 'fest-descans|home-assistant'
```
Check Cloudflare dashboard → Networking → Tunnels → Healthy. Routes are in `components/cloudflared/values.yaml` and must use `<svc>.<ns>.svc.cluster.local`. If cloudflared is fine but the app 5xx's, check the app pod (api needs PostgreSQL; its `migrate` initContainer retries forever while the DB is down). HA 400 Bad Request → trusted proxies (see `homelab-upgrades`).

## 9. SealedSecret not applied

`kubectl get sealedsecrets -A` without `SYNCED True`: `kubectl describe sealedsecret <n> -n <ns>`. "already exists and is not managed" → annotate the Secret `sealedsecrets.bitnami.com/managed=true`. "no key could decrypt" → sealed with another cluster's key; re-seal.

## 10. Can't push from the server

`Password authentication is not supported` → remote is HTTPS. Use SSH: `git remote set-url origin git@github-homelab:eduardolivenza/<repo>.git`, test `ssh -T github-homelab`. `.gitignore` refusing a file (`renovate.json`) → add a `!file` exception, never `-f` on secrets.

## 11. After a reboot

Give it 5–10 min (HDD). `kubectl` may time out at first. Check: `uptime`, `kubectl get nodes`, non-running pods, applications. HA and PostgreSQL need the longest. A reboot that wasn't planned: `journalctl --list-boots`, `sudo journalctl -b -1 -n 50 --no-pager`.
