# Conectar `kubectl` al cluster K3s del Learner Lab (EA2)

Esta guía describe cómo usar **kubectl en tu PC** contra la instancia EC2 que provisiona el workflow **EA2** (K3s). El kubeconfig que trae K3s apunta por defecto a `127.0.0.1`; hay que **apuntarlo a la IP pública** de la VM (o usar **túnel SSH**).

## Contexto en este repositorio

- Workflow: [`.github/workflows/ea2-provision-k8s-sandbox.yaml`](../../.github/workflows/ea2-provision-k8s-sandbox.yaml).
- Tras instalar **k3s**, el archivo de configuración en el servidor es:
  - **`/etc/rancher/k3s/k3s.yaml`**
- El instalador usa `INSTALL_K3S_EXEC="--write-kubeconfig-mode 644"` para que el archivo sea legible con `sudo cat` (ver job en el workflow).
- Usuario SSH de la AMI Ubuntu usada por Terraform (salida `ssh_user`): **`ubuntu`**  
  Ver [`infra/ea2-sandbox-vm/outputs.tf`](../../infra/ea2-sandbox-vm/outputs.tf).

## Requisitos en tu máquina

| Herramienta | Uso |
|-------------|-----|
| `kubectl` | Cliente contra la API del cluster |
| `ssh` | Entrar a la EC2 y/o levantar túnel |
| Clave `.pem` | La misma pareja que configuraste como `EA2_SSH_PRIVATE_KEY` en GitHub Secrets |

## Paso 1 — IP pública y SSH

En el resumen del job de GitHub Actions verás la **IP pública** y el comando SSH de referencia. Ejemplo (sustituye la IP y la ruta a tu clave):

```bash
export LAB_IP='34.231.243.56'
export LAB_KEY="$HOME/.ssh/tu-clave-ea2.pem"
chmod 600 "$LAB_KEY"

ssh -i "$LAB_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@${LAB_IP}" 'echo ok'
```

Si esto falla, revisa Security Group (**puerto 22** desde tu IP o `0.0.0.0/0` según cómo hayas dejado `ssh_cidr_ipv4` en el workflow).

## Paso 2 — Obtener el kubeconfig desde la VM

Opción A — imprimir en pantalla y guardar en un archivo local:

```bash
mkdir -p ~/.kube/lab-k3s
ssh -i "$LAB_KEY" "ubuntu@${LAB_IP}" 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/lab-k3s/k3s.yaml
```

Opción B — una sola línea con `scp`:

```bash
scp -i "$LAB_KEY" "ubuntu@${LAB_IP}:/etc/rancher/k3s/k3s.yaml" ~/.kube/lab-k3s/k3s.yaml
```

En algunos casos `scp` directo al archivo del sistema puede pedir privilegios en el servidor; si falla, usa la opción A con `sudo cat`.

## Paso 3 — Sustituir `127.0.0.1` por la IP pública del Lab

El `server:` suele ser `https://127.0.0.1:6443`. Desde tu PC debe ser la IP **pública** de la EC2:

```bash
sed -i.bak "s|https://127.0.0.1:6443|https://${LAB_IP}:6443|g" ~/.kube/lab-k3s/k3s.yaml
```

En macOS BSD `sed`, usa por ejemplo:

```bash
sed -i '' "s|https://127.0.0.1:6443|https://${LAB_IP}:6443|g" ~/.kube/lab-k3s/k3s.yaml
```

Verifica que el servidor quedó bien:

```bash
kubectl config view --kubeconfig ~/.kube/lab-k3s/k3s.yaml --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

Debe imprimir `https://TU_IP:6443`.

### Certificado TLS (`x509: certificate is valid for … not TU_IP`)

K3s genera el certificado del API server con **SAN** (nombres alternativos) típicos: `127.0.0.1`, IP **privada** de la EC2 (`172.31.x.x`), redes internas del cluster, etc. Si en el kubeconfig pones la **IP pública** pero esa IP **no** está en el certificado, `kubectl` falla con:

```text
tls: failed to verify certificate: x509: certificate is valid for … not 34.x.x.x
```

**Opciones (elige una):**

| Enfoque | Cuándo usar |
|---------|-------------|
| **Túnel SSH** | No quieres tocar K3s en el servidor: deja `server: https://127.0.0.1:6443` en el kubeconfig y usa el apartado [Alternativa — túnel SSH](#alternativa--túnel-ssh-sin-abrir-6443-al-mundo). El certificado ya incluye `127.0.0.1`. |
| **Añadir tu IP pública al certificado (recomendado si usas IP pública sin túnel)** | En la VM, crea o edita `/etc/rancher/k3s/config.yaml` y reinicia K3s (ver bloque abajo). Tras el reinicio, vuelve a copiar `k3s.yaml` si hace falta. |
| **Solo laboratorio — no producción** | En el kubeconfig, en el bloque `clusters[].cluster`, puedes poner `insecure-skip-tls-verify: true` (desactiva verificación TLS; úsalo solo para pruebas). |

**Regenerar certificado con la IP pública en una VM ya instalada** (`LAB_IP` y `LAB_KEY` como antes):

```bash
ssh -i "$LAB_KEY" "ubuntu@${LAB_IP}" bash -s <<EOF
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<YAML
tls-san:
  - "${LAB_IP}"
YAML
sudo systemctl restart k3s
EOF
```

La variable `LAB_IP` se expande **en tu PC** antes de enviar el script al servidor. Si **ya tenías** un `/etc/rancher/k3s/config.yaml` con otros ajustes, **no ejecutes este tee** tal cual: edita el archivo en la VM y añade solo `tls-san:` / `- "TU_IP"`, luego `sudo systemctl restart k3s`.

Los **nuevos** despliegues EA2 instalan K3s con `--tls-san <IP pública>` en el workflow para evitar este paso manual.

## Paso 4 — Red: puerto 6443 (API de Kubernetes)

La API de K3s escucha en **`6443/tcp`** en la instancia. Para que `kubectl` desde tu PC llegue:

- El Terraform de EA2 (`infra/ea2-sandbox-vm`) incluye una regla de entrada **TCP 6443** controlada por la variable **`k8s_api_cidr_ipv4`** (por defecto `0.0.0.0/0` en el workflow). Las instancias creadas **antes** de ese cambio solo tenían SSH + NodePorts: si ves `dial tcp ...:6443: i/o timeout`, era **solo firewall** (Security Group), no un fallo de K3s.
- Si tu MV es antigua, **vuelve a ejecutar el workflow** (o un `terraform apply` con el módulo actualizado) o añade a mano en la consola AWS: **entrada TCP 6443** desde tu IP (recomendado) o `0.0.0.0/0` solo en laboratorio.

Si **no** puedes abrir el 6443 hacia Internet, usa el **túnel SSH** del siguiente apartado.

## Paso 5 — Usar `kubectl` con ese archivo

No sobreescribas tu `~/.kube/config` personal si no quieres; usa `KUBECONFIG`:

```bash
export KUBECONFIG="$HOME/.kube/lab-k3s/k3s.yaml"
kubectl get nodes
kubectl cluster-info
```

Para volver a tu contexto habitual:

```bash
unset KUBECONFIG
```

## Alternativa — túnel SSH (sin abrir 6443 al mundo)

Si el kubeconfig sigue apuntando a `https://127.0.0.1:6443`, en **tu máquina** levantas un forward local al puerto remoto **6443**:

```bash
ssh -i "$LAB_KEY" -N -L 6443:127.0.0.1:6443 "ubuntu@${LAB_IP}"
```

Deja esa sesión abierta. En **otra** terminal:

```bash
export KUBECONFIG="$HOME/.kube/lab-k3s/k3s.yaml"
# Asegúrate de que server sea https://127.0.0.1:6443 (restaura desde .bak si cambiaste antes)
kubectl get nodes
```

Desde tu PC el tráfico va cifrado por SSH hasta la VM y allí llega a la API local del K3s.

## Si elegiste `minikube` en lugar de `k3s`

El workflow también puede instalar Minikube. Ahí el kubeconfig y los comandos **no** son los de `/etc/rancher/k3s/k3s.yaml`; suele usarse `sudo minikube kubectl --` en la VM o exportar el config que Minikube genere en el servidor. Esta guía está centrada en **`k8s_stack: k3s`** (predeterminado en EA2).

---

## Validación local de los comandos (sin cluster real)

Los siguientes pasos **no** comprueban conectividad a AWS; solo validan que la cadena de comandos y `kubectl` funcionan en una máquina de desarrollo. Ejecutados en Fedora Linux el **2026-04-18**:

```bash
# Cliente kubectl disponible
kubectl version --client
# Ejemplo de salida esperada (versión puede variar):
# Client Version: v1.34.x
# Kustomize Version: v5.x.x

# Cliente SSH disponible
ssh -V
# Ejemplo: OpenSSH_10.x ...

# Validar lectura de kubeconfig y sustitución de URL con sed + kubectl config view
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: QkRBRkstZHVtbXktYmFzZTY0
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
users:
- name: default
  user:
    token: ejemplo-validacion-local
preferences: {}
EOF
kubectl config view --kubeconfig="$TMP" --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
sed 's|https://127.0.0.1:6443|https://34.231.243.56:6443|' "$TMP" > "${TMP}.new"
kubectl config view --kubeconfig="${TMP}.new" --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
rm -f "$TMP" "${TMP}.new"
# Primera línea: https://127.0.0.1:6443
# Segunda línea: https://34.231.243.56:6443
```

La salida debe mostrar primero la URL con `127.0.0.1` y, tras `sed`, la URL con la IP sustituida. Eso confirma que los pasos de edición del README son coherentes con `kubectl`.

---

## Diagnóstico rápido

| Síntoma | Qué revisar |
|---------|-------------|
| `connection timed out` hacia `:6443` | Security Group (entrada 6443), o usar túnel SSH |
| `x509: certificate is valid for … not <tu IP pública>` | El certificado del API no incluye la IP elástica: **túnel SSH** con `127.0.0.1`, o **`tls-san`** en `/etc/rancher/k3s/config.yaml` + `systemctl restart k3s`, o EA2 actualizado con `--tls-san` en instalaciones nuevas |
| `Unable to connect to the server: x509` (genérico) | IP equivocada en `server:` o certificado que no coincide con ese host |
| `Forbidden` / `Unauthorized` | Estás usando un kubeconfig viejo o token revocado; vuelve a copiar `/etc/rancher/k3s/k3s.yaml` del servidor |

## Referencias en el repo

- Ejemplo de invocación desde el repo del alumno: [`examples/ea2-invoke-from-student-repo.yaml`](../../examples/ea2-invoke-from-student-repo.yaml).
- Infra Terraform del sandbox: [`infra/ea2-sandbox-vm/README.md`](../../infra/ea2-sandbox-vm/README.md).
