# homelab

Todo el servidor `asusold` (K3s) descrito como código y desplegado por ArgoCD.

```
bootstrap/root-app.yaml   # lo único que se aplica a mano
argocd-apps/              # una Application por componente (las gestiona "root")
platform/
  argocd/                 # ArgoCD gestionándose a sí mismo (v3.4.4)
  cloudflared/            # túnel de Cloudflare (namespace cloudflared)
apps/
  home-assistant/         # values del chart de HA
  fest-descans/secrets/   # SealedSecrets de la web
```

La web (código, CI y charts) sigue en [fest-page](https://github.com/eduardolivenza/fest-page).
Aquí solo se declara qué se despliega.

---

## Migración desde el estado actual

Lo que ya existe en el cluster con el mismo nombre (`fest-descans`, `home-assistant`)
se adopta sin redesplegar.

### 1. Root app + Sealed Secrets

```bash
kubectl apply -f bootstrap/root-app.yaml
```

ArgoCD crea `argocd`, `sealed-secrets`, `cloudflared`, `fest-descans` y `home-assistant`.
`cloudflared` y `fest-descans-secrets` fallan hasta que existan sus secretos (paso 2): es normal.

### 2. Cifrar los secretos (se hace una vez)

Instala `kubeseal` en el servidor:

```bash
KUBESEAL_VERSION=0.36.1   # mira la última en github.com/bitnami-labs/sealed-secrets/releases
curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz | tar xz kubeseal
sudo install kubeseal /usr/local/bin/
```

Sella los secretos que ya existen (se leen del cluster, no hace falta saber los valores):

```bash
seal() {  # seal <namespace-origen> <secret> <namespace-destino> <fichero-salida>
  kubectl get secret "$2" -n "$1" -o yaml \
    | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels, .metadata.ownerReferences, .metadata.managedFields) | .metadata.namespace = "'"$3"'"' \
    | kubeseal -o yaml > "$4"
}
seal fest-descans ghcr-credentials        fest-descans apps/fest-descans/secrets/ghcr-credentials.yaml
seal fest-descans fest-descans-api        fest-descans apps/fest-descans/secrets/fest-descans-api.yaml
seal fest-descans cloudflared-credentials cloudflared  platform/cloudflared/templates/sealed-credentials.yaml
git add -A && git commit -m "Add sealed secrets" && git push
```

Los ficheros generados están cifrados: se pueden subir a Git sin problema.
Solo el controlador del cluster puede descifrarlos.

> **Backup de la clave del controlador.** Si reinstalas el cluster sin ella, no podrás descifrar nada:
> `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml`
> y guárdalo FUERA de Git (gestor de contraseñas, por ejemplo).

### 3. Quitar cloudflared de fest-page

Cuando el pod `cloudflared` del namespace `cloudflared` esté `Running` (los dos
despliegues pueden convivir: son conectores del mismo túnel), en el repo fest-page:

- borra `helm/cloudflared/`
- borra `argocd/fest-descans-appset.yaml` (ahora vive aquí)

ArgoCD eliminará el `fest-descans-cloudflared` antiguo. Comprueba que
festdescans.com y homeassistant.festdescans.com siguen respondiendo.

### 4. Limpieza

```bash
# ConfigMap aplicado a mano que ningún pod usa (sensor del termostato)
kubectl get cm home-assistant-config -n home-assistant -o yaml > ~/home-assistant-config.backup.yaml
kubectl delete cm home-assistant-config -n home-assistant
```

---

## Pendiente (siguientes fases)

- Fijar la versión de la imagen de Home Assistant (`apps/home-assistant/values.yaml`).
- Configuración YAML de HA (`packages/`, sensor del termostato) versionada aquí.
- Registros DNS y túnel de Cloudflare con OpenTofu.
- Configuración de K3s y del host con Ansible.
- Renovate para actualizaciones automáticas de versiones.
- Revisar el estado de sync `Unknown` de las apps de fest-descans.
