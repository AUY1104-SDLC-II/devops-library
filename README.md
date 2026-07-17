# DevOps Library — AUY1104

Biblioteca de workflows reutilizables de GitHub Actions para estandarizar la construcción, publicación y despliegue de aplicaciones de la organización `AUY1104-SDLC-II`.

## Objetivo

Este repositorio separa las responsabilidades comunes del pipeline:

- Ejecutar pruebas automatizadas.
- Construir una imagen desde el `Dockerfile` del repositorio caller.
- Publicar la imagen en Docker Hub con `github.sha`.
- Desplegar una estrategia Canary en Kubernetes/K3s.
- Validar Stable y Canary.
- Promover Canary cuando las validaciones son exitosas.
- Restaurar Stable automáticamente cuando ocurre un fallo.

## Arquitectura

```text
Repositorio caller
        |
        | workflow_call
        v
devops-library
├── eft-docker-deploy.yaml
└── eft-canary-deploy.yaml
        |
        | Docker Hub + SSH/SCP
        v
Amazon EC2
        |
        v
K3s / Kubernetes
```

La pauta original utiliza Amazon EKS y ECR. Debido a restricciones del laboratorio, esta implementación utiliza Amazon EC2 con K3s y Docker Hub, conservando los principios evaluados de CI/CD, Kubernetes, despliegue avanzado y remediación automática.

## Workflows reutilizables

### Build y Push de Docker

Archivo:

```text
.github/workflows/eft-docker-deploy.yaml
```

Responsabilidades:

1. Descargar el repositorio caller.
2. Configurar Node.js 20.
3. Ejecutar `npm ci` y `npm test`.
4. Autenticarse en Docker Hub.
5. Construir la imagen usando el `Dockerfile` del caller.
6. Publicar la imagen:

```text
<DOCKER_USERNAME>/auy1104-app:<github.sha>
```

Secrets requeridos:

```text
DOCKER_USERNAME
DOCKER_PASSWORD
```

Si las pruebas o la construcción fallan, no se publica la imagen y el workflow Deploy no comienza.

### Deploy Canary en K3s

Archivo:

```text
.github/workflows/eft-canary-deploy.yaml
```

Inputs:

| Input | Requerido | Predeterminado | Propósito |
|---|---:|---|---|
| `stable_image` | Sí | — | Imagen conocida que protege el despliegue. |
| `server_ip` | Sí | — | IP pública de la instancia EC2. |
| `image_name` | No | `auy1104-app` | Repositorio de imagen Docker. |
| `namespace` | No | `canary-orders` | Namespace Kubernetes de destino. |

Secrets:

| Secret | Propósito |
|---|---|
| `DOCKER_USERNAME` | Construir la referencia Canary. |
| `EA2_SSH_PRIVATE_KEY` | Autenticación SSH contra EC2. |

La imagen Canary se calcula como:

```text
<DOCKER_USERNAME>/<image_name>:<github.sha>
```

## Flujo Canary

```text
Stable conocida
      |
      v
Canary aislada
      |
      v
rollout status + /health
      |
      v
Tráfico aproximado 75/25
      |
      +------ fallo ------> rollback a Stable
      |
      +------ éxito ------> promoción a Stable
```

### Stable

- Deployment `orders-api-stable`.
- Tres réplicas.
- Label `track: stable`.
- Imagen entregada mediante `stable_image`.
- Readiness y liveness probes en `/health`.

### Canary

- Deployment `orders-api-canary`.
- Una réplica.
- Label `track: canary`.
- Imagen basada en el SHA del caller.
- Service interno `orders-api-canary-validation`.

### División de tráfico

El Service público comienza apuntando a Stable:

```yaml
selector:
  app: orders-api
  track: stable
```

Después de validar Canary, el workflow elimina temporalmente `track`. El Service selecciona tres pods Stable y un pod Canary, generando una distribución aproximada 75%/25%.

La distribución no es una ponderación exacta por solicitud; Kubernetes balancea conexiones entre los endpoints disponibles.

### Promoción

Cuando Canary supera las validaciones:

1. El Service vuelve a `track: stable`.
2. Stable adopta la imagen Canary.
3. `rollout status` espera que Stable quede disponible.
4. Canary se elimina.
5. Se valida nuevamente `/health`.

### Rollback

Ante cualquier fallo:

1. El Service vuelve a `track: stable`.
2. Stable recupera `stable_image`.
3. Se espera su rollout.
4. Canary se elimina si existe.
5. Se valida nuevamente `/health`.
6. El resultado se registra en `GITHUB_STEP_SUMMARY`.

El workflow puede finalizar en rojo aunque el rollback sea exitoso. Esto conserva evidencia del incidente y de la recuperación automática.

## Ejemplo de uso

```yaml
name: EFT - Pipeline Canary completo

on:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: canary-orders-deployment
  cancel-in-progress: false

jobs:
  build:
    uses: AUY1104-SDLC-II/devops-library/.github/workflows/eft-docker-deploy.yaml@main
    secrets: inherit

  deploy:
    needs: build
    uses: AUY1104-SDLC-II/devops-library/.github/workflows/eft-canary-deploy.yaml@main
    with:
      stable_image: mafernandezz/auy1104-app@sha256:8cf9ad3c7a1ae510034a85eaa00107edf167ac785e29165e8f5985581c5c59b4
      server_ip: ${{ vars.K3S_SERVER_PUBLIC_IP }}
      image_name: auy1104-app
      namespace: canary-orders
    secrets: inherit
```

`needs: build` impide el despliegue si tests, construcción o publicación fallan.

## Contrato del repositorio caller

El caller debe contener:

```text
Dockerfile
package.json
package-lock.json
src/
tests/
k8s/
├── canary-namespace.yaml
├── canary-stable-deployment.yaml
├── canary-deployment.yaml
└── canary-service.yaml
```

Los Deployments deben incluir:

```text
STABLE_IMAGE_PLACEHOLDER
CANARY_IMAGE_PLACEHOLDER
```

El workflow reemplaza estos valores antes de copiar los manifiestos a EC2.

## Componentes externos

| Componente | Justificación |
|---|---|
| `actions/checkout@v4` | Descarga estandarizada del repositorio caller. |
| `actions/setup-node@v4` | Instalación reproducible de Node.js. |
| `docker/login-action@v3` | Autenticación segura contra Docker Hub. |
| `docker/build-push-action@v5` | Construcción y publicación mediante BuildKit. |
| `webfactory/ssh-agent@v0.9.0` | Carga de la llave SSH desde GitHub Secrets. |


## Seguridad

- Credenciales almacenadas en GitHub Secrets.
- Llaves privadas ausentes del código.
- Imágenes Canary identificadas por SHA.
- Stable puede fijarse mediante digest.
- SSH utiliza `StrictHostKeyChecking=accept-new`.
- El caller aplica `permissions: contents: read`.
- La concurrencia evita despliegues simultáneos.

## Escenarios de prueba

### Fallo en tests

```text
npm test falla
→ no se construye imagen
→ no se publica
→ Deploy no comienza
```

### Imagen Canary inexistente

```text
ErrImagePull
→ ImagePullBackOff
→ rollout status falla
→ rollback automático
→ Stable continúa disponible
```

### Fallo de salud

Una readiness probe inválida o una respuesta HTTP no exitosa impide la promoción y activa el rollback.

## Valor técnico y de negocio

- Reduce errores manuales.
- Disminuye el MTTR.
- Limita el radio de impacto de nuevas versiones.
- Mantiene disponibilidad mediante Stable.
- Mejora el time-to-market.
- Relaciona commit, imagen y despliegue mediante `github.sha`.
- Permite reutilizar Build y Deploy entre proyectos.

## Limitaciones

- K3s sustituye EKS por restricciones del laboratorio.
- Docker Hub sustituye ECR.
- El reparto 75/25 es aproximado.
- El caller debe actualizar `stable_image` después de una promoción.
- La observabilidad utiliza probes, rollouts, endpoints y logs de Actions.

## Citas y referencias

Las citas directas, paráfrasis y referencias externas deben presentarse según normas APA, séptima edición.

Docker. (s. f.). *Build and push Docker images*. GitHub Marketplace. Recuperado el 17 de julio de 2026, de https://github.com/marketplace/actions/build-and-push-docker-images

GitHub. (s. f.). *Reuse workflows*. GitHub Docs. Recuperado el 17 de julio de 2026, de https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows

Kubernetes Authors. (s. f.). *Deployments*. Kubernetes Documentation. Recuperado el 17 de julio de 2026, de https://kubernetes.io/docs/concepts/workloads/controllers/deployment/

Kubernetes Authors. (s. f.). *Service*. Kubernetes Documentation. Recuperado el 17 de julio de 2026, de https://kubernetes.io/docs/concepts/services-networking/service/

Kubernetes Authors. (s. f.). *Configure liveness, readiness and startup probes*. Kubernetes Documentation. Recuperado el 17 de julio de 2026, de https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/

## Declaración de uso de inteligencia artificial

Se utilizó inteligencia artificial generativa como apoyo para revisar workflows, analizar errores, estructurar pruebas y organizar esta documentación. La responsabilidad sobre la exactitud, ejecución y entrega corresponde a Matías Fernández

## Autor

Matías Fernández — AUY1104, Ciclo de Vida del Software II.