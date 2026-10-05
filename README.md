# techo360-infra

Este repositorio contiene la orquestación de contenedores y los scripts de
despliegue para el proyecto **Techo 360**. No contiene código de aplicación:
ese vive en los otros 4 repos (`techo360-frontend`, `techo360-backend`,
`techo360-chatbot`, `techo360-proyeccion`), clonados como carpetas hermanas
de esta en el servidor.

> **Nota de versión:** este repo reemplaza la versión anterior de hace un
> par de semanas. El microservicio único `techo360-ai-service` se dividió
> en dos repos independientes (`techo360-chatbot` y `techo360-proyeccion`),
> y la base de datos única de Postgres se dividió en tres (principal con
> PostGIS, vectorial con pgvector, y de usuarios/logs), según la
> arquitectura definida para el proyecto. También se agregaron RabbitMQ
> (colas entre los 3 servicios) y Ollama (LLM local para el chatbot).

## Estructura esperada en el servidor

```
/opt/techo360/
├── techo360-frontend/
├── techo360-backend/
├── techo360-chatbot/
├── techo360-proyeccion/
└── techo360-infra/          <- este repo
    ├── docker-compose.yml
    ├── docker-compose.dev-db.yml
    ├── .env                  (creado a partir de .env.example, nunca en git)
    ├── db-init/
    └── scripts/
```

## Filosofía de despliegue: aislamiento por servicio

Cada uno de los 4 repos de servicio tiene su propio workflow de GitHub Actions
(ver `workflow-templates/` en este repo para copiarlos). Cuando alguien hace
push a `development` en, por ejemplo, `techo360-chatbot`, **solo se reconstruye
y reinicia el contenedor del chatbot** — las bases de datos, Redis, RabbitMQ,
Ollama, el backend, la proyección y el frontend siguen corriendo sin
interrupción.

Cuando lo que cambia es este mismo repo de infra (límites de recursos, redes,
variables), se usa un flujo distinto que sí re-aplica configuración a todos
los servicios, ya que un cambio de infraestructura por naturaleza puede
afectarlos a todos.

## Arquitectura desplegada

**Puertos aprobados por el CCA para acceso desde fuera del campus:**
22 (ssh-sftp), 80 (http), 443 (https), 5432 (postgresql), ping/snmp.
Por eso `backend` y `chatbot` NO exponen puerto propio — `frontend`
(Nginx) hace de reverse proxy y enruta `/api/` y `/chatbot/` hacia
ellos internamente. El 5432 público es un puerto aprobado, distinto del
acceso a las 3 bases vía Tailscale descrito más abajo (ese es tráfico
de la red superpuesta cifrada, no de la interfaz pública).

| Contenedor | Rol | Puerto expuesto |
|---|---|---|
| `frontend` | React + Nginx (sirve la SPA y hace de reverse proxy hacia backend/chatbot) | 80 (443 cuando haya DNS/TLS) |
| `backend` | Mapa de calor, autenticación, actualización de datos | — (interno, vía proxy del frontend) |
| `chatbot` | LLM propio + RAG (pgvector) | — (interno, vía proxy del frontend) |
| `proyeccion` | Proyección de series de tiempo (sin LightGBM desde 23-sep-2026) | — (interno, solo vía RabbitMQ) |
| `postgres-principal` | PostgreSQL + PostGIS | Tailscale: `100.116.197.118:5432` |
| `postgres-vector` | PostgreSQL + pgvector (compartida chatbot/proyeccion) | Tailscale: `100.116.197.118:5433` |
| `postgres-users` | PostgreSQL (usuarios, roles, logs) | Tailscale: `100.116.197.118:5434` |
| `redis` | Cache + OTP | — (interno) |
| `rabbitmq` | Broker de colas | — (panel admin no expuesto por defecto) |
| `ollama` | LLM local (CPU-only, sin GPU en este VPS) | — (interno) |

**Nota sobre el acceso a las 3 bases de datos vía Tailscale:** cada una
publica su puerto únicamente en la IP privada de Tailscale
(`100.116.197.118`), nunca en `0.0.0.0` ni en la IP pública del
servidor. Es el patrón para acceso remoto del DBA/desarrollo
(pgAdmin/DBeaver) sin exponer Postgres a internet — al ser tráfico
dentro de la red superpuesta cifrada de Tailscale, no cuenta contra el
límite de puertos aprobados por el CCA.

## Scripts

| Script | Cuándo se usa |
|---|---|
| `scripts/setup-server.sh` | Una sola vez, al preparar un servidor nuevo desde cero |
| `scripts/deploy-service.sh <servicio>` | En cada push a un repo de servicio (backend, chatbot, proyeccion, frontend) |
| `scripts/deploy-infra.sh` | En cada push a este repo (techo360-infra) |
| `scripts/rollback-service.sh <servicio>` | Automático si un deploy falla, o manual si algo se rompe después |
| `scripts/backup-db.sh` | Automático antes de cada deploy; respalda las 3 bases de datos, conserva las últimas 2 copias de cada una |
| `scripts/freeze-tag.sh <nombre>` | Antes de una entrega/demo, para congelar una versión estable de los 4 servicios |

## Primeros pasos en un servidor nuevo

```bash
# 1. Clonar este repo (o correr setup-server.sh que ya lo hace por ti)
git clone https://github.com/JuacoDev/techo360-infra.git

# 2. Configurar variables de entorno
cd techo360-infra
cp .env.example .env
nano .env   # completar contraseñas reales (3 bases de datos + RabbitMQ)

# 3. Primer arranque completo
docker compose up -d --build

# 4. Verificar que todo esté corriendo
docker compose ps

# 5. Descargar el modelo del LLM en Ollama (una sola vez, no es automático)
docker exec -it techo360-ollama ollama pull llama3.2:3b
```

## ⚠️ Nota sobre el LLM y la RAM del servidor

El VPS del CCA **no tiene GPU** (8GB RAM, 2 cores). Ollama corriendo por CPU
con un modelo de 7-8B parámetros puede saturar la memoria disponible una vez
sumadas las 3 bases de datos, RabbitMQ, los 3 microservicios y el frontend.

Por eso el contenedor de `ollama` tiene un límite de `3072m` y **se recomienda
usar un modelo pequeño (1-3B, ej. `llama3.2:3b` o `phi3:mini`) para lo que
corra en producción en este servidor**. El entrenamiento/experimentación con
modelos más grandes se hace en las GPUs locales del equipo (3050, 5060, RTX
4000), no en este VPS.

## Base de datos de desarrollo (segundo Postgres aislado)

Antes de integrar un cambio de esquema a cualquiera de las 3 bases reales, se
prueba primero en un contenedor aislado:

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

## Pruebas operativas del 5-oct-2026

Resumen de las pruebas y cambios operativos del 5-oct-2026 en producción (VPS). Marcas: **COMPROBADO** = medido o verificado con comandos; **HIPÓTESIS** = inferido; **no verificado** = no se pudo comprobar. Borrador de origen: `techo360-pendientes/PRUEBAS_OPERATIVAS_2026-10-05.md` (fuera de los repos).

### Latencias de estrés (confirmadas por la base; todas anteriores a D11)
- 3 envíos simultáneos: 46,3 s, 81,0 s y 119,7 s.
- 4 envíos simultáneos: 46,9 s, 94,3 s, 147,5 s y 183,8 s.
- Capacidad medida: 4 simultáneos con 16 s de margen frente al tope de 200 s del backend. El quinto no se probó.

### Monitoreo del chatbot (60 min, solo lectura)
- Memoria máxima de Ollama: 81,9 % de 3 GiB.
- Throttling >50 % durante cada generación (la CPU de Ollama se satura contra su cuota de 3 CPU). En la medición directa de D11 bajó de 78 % a 5 %.
- Cola `chatbot_requests`: máximo de 4 mensajes.
- 0 OOM y 0 reinicios **de Ollama**. El chatbot y el frontend sí se recrearon por D11 y D12.
- Las únicas 2 muestras de `/health` fuera de 200 coinciden con esos recreados (chatbot 502 en D11 y 000 en D12; el `/health` del chatbot pasa por el nginx del frontend).

### D11 (`num_thread = 3` en el chatbot)
- 5,32 → 7,18 tokens/s, medición directa a Ollama con un prompt corto (62–66 tokens). El efecto con respuestas reales por la app no está verificado.

### D12 (timeouts de 210 s en `/chatbot/mensajes`)
- El frontend estuvo inaccesible ~0,8–0,9 s durante el recreado, medido desde dentro del VPS.

### Incidencias de red
- Dos cortes de acceso al VPS desde el PC de trabajo (~19:56 y ~21:15 UTC), ambos resueltos cambiando de red.
- `fail2ban` inactivo. El journal de sshd solo se revisó para el segundo corte (~20:55–21:30 UTC) y no muestra intentos fallidos ni bloqueos; para el primero no se revisó.
- `ufw` e `iptables` no se pudieron revisar sin `sudo`. Causa de los cortes: desconocida.

### No verificado
- Nivel 5: el quinto envío simultáneo no se probó.
- Reintentar con la cola ocupada y el posible 504 de nginx (D12 sube el timeout, pero el caso no se reprodujo).
- El efecto de D11 medido por la app con respuestas reales.
- El reencolado de un mensaje en vuelo al recrear el chatbot (en D10 y D11 no había mensajes en curso).
- Los proxies o firewalls fuera del VPS.
- `ufw` e `iptables`.
- La causa de los dos cortes de red.

<!-- prueba CI/CD -->
