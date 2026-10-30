---
name: homelab-secrets
description: Sealed Secrets on the homelab — which secrets exist, how to read, create, rotate and seal them, the controller key backup, and recovery if the key is lost. Use whenever a task touches credentials or Kubernetes Secrets.
---

# Secrets (Sealed Secrets)

## Model

- Git holds `SealedSecret` objects (encrypted with the controller's public key). Safe to commit.
- The controller `sealed-secrets-controller` (ns `kube-system`, chart `sealed-secrets` from `https://bitnami.github.io/sealed-secrets`) decrypts them into normal `Secret`s.
- A SealedSecret is bound to **name + namespace** (strict scope). Moving a secret to another namespace = re-seal.
- Plaintext never goes to Git. `.gitignore` blocks `*.json`, `*-secret.yaml`, `*.unsealed.yaml`, `.env`.

## Inventory

| Secret | Namespace | SealedSecret file | Keys | Used by |
|---|---|---|---|---|
| `ghcr-credentials` | fest-descans | **fest-page** `helm/api/templates/sealed-ghcr-credentials.yaml` | `.dockerconfigjson` | image pulls from ghcr.io (GitHub PAT) |
| `fest-descans-api` | fest-descans | **fest-page** `helm/api/templates/sealed-secret.yaml` | `JWT_SECRET`, `password`, `postgres-password` | api + PostgreSQL (Bitnami `existingSecret`) |
| `cloudflared-credentials` | cloudflared | `platform/cloudflared/templates/sealed-credentials.yaml` | `credentials.json` | tunnel `96ed517e-…` |
| `argocd-initial-admin-secret` | argocd | not in Git | `password` | ArgoCD admin first login (delete after changing the password) |

**Rule (since 2026-10-30):** an app's secrets live in the repo that owns the app's chart, as
SealedSecrets inside the chart's `templates/` (deployed and pruned with the app). This repo only holds
secrets of shared/platform components (cloudflared). See decision D15.
`ghcr-credentials` is in the api chart but used by web, admin and api (same namespace); each chart's
`values.yaml` sets `global.imagePullSecrets: [{name: ghcr-credentials}]`. Images stay private (decided
2026-10-30), so the GitHub PAT inside it must be renewed when it expires.

## Read a secret

```bash
kubectl get secrets -A
kubectl get secret <name> -n <ns> -o go-template='{{range $k,$v := .data}}{{$k}} = {{$v | base64decode}}{{"\n"}}{{end}}'
```
Or `k9s` → `:secrets` → `x`. The ArgoCD UI masks secret values.

## Create or rotate (never `kubectl edit` — Git would overwrite it)

```bash
cd ~/repositories/homelab && git pull
kubectl create secret generic <name> -n <ns> \
  --from-literal=KEY='value' [--from-file=key=path] \
  --dry-run=client -o yaml | kubeseal -o yaml > <path-in-repo>.yaml
git add <path> && git commit -m "Rotate <name>" && git push
```
- Path: for fest-descans secrets, `~/repositories/fest-page/helm/api/templates/<file>.yaml` (commit in fest-page, `git pull --rebase` first). For platform secrets, the component's chart `templates/` in this repo.
- SealedSecrets inside a Helm chart go under `templates/`. Base64 contains no `{{`, so Helm passes them through (check: `grep -c '{{' file` → 0, and `helm template` renders it).
- Moving a SealedSecret file between repos/charts needs no re-sealing (it is bound to name + namespace, not to a path). Safe move: stop managing it in the old app first (Application without finalizer, or remove the file with prune off), then add it to the new app; check `metadata.annotations["argocd.argoproj.io/tracking-id"]`.
- **Database passwords**: changing `password` / `postgres-password` in the secret does NOT change them inside PostgreSQL (Bitnami only reads them at first init). Run `ALTER USER ... PASSWORD` in PostgreSQL in the same maintenance window.

## Seal a secret that already exists in the cluster (migration recipe)

```bash
seal() {  # seal <ns-from> <secret> <ns-to> <out-file>
  kubectl get secret "$2" -n "$1" -o yaml \
    | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels, .metadata.ownerReferences, .metadata.managedFields) | .metadata.namespace = "'"$3"'"' \
    | kubeseal -o yaml > "$4"
}
```
If the target Secret already exists and was created by hand, the controller refuses to overwrite it until you annotate it:
`kubectl annotate secret <name> -n <ns> sealedsecrets.bitnami.com/managed="true"`.

Check: `kubectl get sealedsecrets -A` → `SYNCED True`; `kubectl describe sealedsecret <name> -n <ns>` → `Unsealed successfully`.

## Tools

- `kubeseal` in `/usr/local/bin` (match the controller version, e.g. `v0.41.2`):
  `curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.41.2/kubeseal-0.41.2-linux-amd64.tar.gz | tar xz kubeseal && sudo install kubeseal /usr/local/bin/`
- `yq` (mikefarah, installed via snap).

## The controller key (critical)

Backup taken on 2026-10-28 at `~/sealed-secrets-key.backup.yaml` on the server. It must also live outside the server (password manager). **Never commit it.**
```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/sealed-secrets-key.backup.yaml
```
The controller rotates (adds) keys every 30 days by default; re-take the backup periodically (it contains all keys).

Restore on a new cluster **before** the controller starts (see `homelab-disaster-recovery`):
`kubectl apply -f sealed-secrets-key.backup.yaml` then deploy the controller (or `kubectl delete pod -n kube-system -l app.kubernetes.io/name=sealed-secrets` to reload).

If the key is lost: every SealedSecret is useless. Recreate from source values and re-seal:
- `cloudflared-credentials`: on a machine with a browser, `cloudflared tunnel login` then `cloudflared tunnel token --cred-file credentials.json fest-descans` regenerates the credentials file for the existing tunnel. Alternative: create a new tunnel and update `tunnelId` in `platform/cloudflared/values.yaml` + the DNS CNAMEs.
- `ghcr-credentials`: new GitHub PAT with `read:packages`.
- `fest-descans-api`: new `JWT_SECRET` (logs everyone out); DB passwords must match what's inside PostgreSQL (or reset them with `ALTER USER`).
