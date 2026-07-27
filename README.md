# techo360-infra

Este repositorio contiene la orquestación de contenedores y los scripts de
despliegue para el proyecto **Techo 360**. No contiene código de aplicación:
ese vive en los otros 3 repos (`techo360-frontend`, `techo360-backend`,
`techo360-ai-service`), clonados como carpetas hermanas de esta en el servidor.

## Estructura esperada en el servidor

```
/opt/techo360/
├── techo360-frontend/
├── techo360-backend/
├── techo360-ai-service/
└── techo360-infra/          <- este repo
    ├── docker-compose.yml
    ├── docker-compose.dev-db.yml
    ├── .env                  (creado a partir de .env.example, nunca en git)
    └── scripts/
```

## Filosofía de despliegue: aislamiento por servicio

Cada uno de los 3 repos de servicio tiene su propio workflow de GitHub Actions
(ver `workflow-templates/` en este repo para copiarlos). Cuando alguien hace
push a `development` en, por ejemplo, `techo360-backend`, **solo se reconstruye
y reinicia el contenedor del backend** — Postgres, Redis, frontend y el
microservicio de IA siguen corriendo sin interrupción.

Cuando lo que cambia es este mismo repo de infra (límites de recursos, redes,
variables), se usa un flujo distinto que sí re-aplica configuración a todos
los servicios, ya que un cambio de infraestructura por naturaleza puede
afectarlos a todos.

## Scripts

| Script | Cuándo se usa |
|---|---|
| `scripts/setup-server.sh` | Una sola vez, al preparar un servidor nuevo desde cero |
| `scripts/deploy-service.sh <servicio>` | En cada push a un repo de servicio (backend, ai-service, frontend) |
| `scripts/deploy-infra.sh` | En cada push a este repo (techo360-infra) |
| `scripts/rollback-service.sh <servicio>` | Automático si un deploy falla, o manual si algo se rompe después |
| `scripts/backup-db.sh` | Automático antes de cada deploy; conserva las últimas 2 copias |
| `scripts/freeze-tag.sh <nombre>` | Antes de una entrega/demo, para congelar una versión estable |

## Primeros pasos en un servidor nuevo

```bash
# 1. Clonar este repo (o correr setup-server.sh que ya lo hace por ti)
git clone https://github.com/JuacoDev/techo360-infra.git

# 2. Configurar variables de entorno
cd techo360-infra
cp .env.example .env
nano .env   # completar contraseñas reales

# 3. Primer arranque completo
docker compose up -d --build

# 4. Verificar que todo esté corriendo
docker compose ps
```

## Base de datos de desarrollo (segundo Postgres aislado)

Antes de integrar un cambio de esquema al Postgres real, se prueba primero en
un contenedor aislado:

```bash
docker compose -f docker-compose.dev-db.yml up -d
# ... hacer las pruebas con pgAdmin/DBeaver, conectando por Tailscale al puerto 55432 ...
docker compose -f docker-compose.dev-db.yml down   # apagarlo cuando no se necesite
```

## Convención de etiquetas de imagen

- `dev`: se actualiza automáticamente en cada push a `development`. Es lo que
  corre normalmente durante el desarrollo del sprint.
- Etiquetas congeladas (ej. `sprint1-demo`): creadas con `freeze-tag.sh` antes
  de una entrega, para que el equipo pueda seguir haciendo push a `development`
  sin arriesgar la demo con cambios de último momento.

<!-- Prueba de despliegue automatico: 2026-07-27 11:04:16 -->

<!-- Prueba 2 de despliegue: 2026-07-27 11:13:56 -->

<!-- Prueba 3 de despliegue: 2026-07-27 11:33:21 -->
