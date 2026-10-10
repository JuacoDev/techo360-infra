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

## Serialización de deploys y orden de arranque (T-127)

**Carrera entre runners.** El VPS tiene un runner self-hosted por repo (`actions-runner-infra`, `-frontend`, `-backend`, `-chatbot`, `-proyeccion`), todos con el usuario `techo360-admin`. `deploy-infra.sh` ejecuta `docker compose up -d` sobre todos los servicios y `deploy-service.sh` ejecuta `up -d --no-deps <servicio>`; si dos pushes coinciden, ambos recrean el mismo contenedor a la vez y falla con "container name already in use" (26-sep-2026, 3 runs). El `concurrency` de GitHub Actions no sirve aquí porque sus grupos no se comparten entre repos.

**Mitigación.** `deploy-infra.sh` y `deploy-service.sh` toman un `flock` exclusivo sobre `/opt/techo360/logs/.deploy.lock` (espera máxima 1800 s; si expira o falla, abortan con `exit 1` y no continúan sin candado). Es cross-repo porque todos los workflows llaman a estos scripts. Ningún workflow define `timeout-minutes` (el default de GitHub es 360 min, mayor que los 30 min del candado). `rollback-service.sh` no toma candado: lo invoca `deploy-service.sh`, que ya lo tiene; un rollback manual no está serializado.

**Alcance de `service_healthy`.** `backend`, `proyeccion` y `chatbot` esperan a RabbitMQ con `condition: service_healthy`. `deploy-service.sh` usa `--no-deps`, que no evalúa `depends_on`: la espera solo aplica a `deploy-infra.sh` (`up -d` completo) y a un `up` manual. Un deploy de un solo servicio no espera a RabbitMQ.

**Deuda: resolver DNS de nginx (repo `techo360-frontend`, no modificado).** `nginx.conf` usa `proxy_pass http://backend:8000` / `http://chatbot:8000`, que nginx resuelve una sola vez al arrancar. Si backend o chatbot se recrean, nginx conserva la IP vieja hasta un `nginx -s reload` (visto el 26-sep-2026). Propuesta: `resolver 127.0.0.11 valid=10s;` y `proxy_pass` con variable (`set $backend http://backend:8000;`), cuidando que con variable el `proxy_pass` no recorta la URI y hay que revisar cada `location`.

**Bug de reconexión de consumers y prueba final en producción (6-oct-2026).** Un recreate de RabbitMQ dejaba a backend, chatbot y proyeccion conectados pero con `consumer_count=0` (sin excepción ni log): aio-pika 9.4.3 guarda las colas de cada canal en un `WeakSet` (`RobustChannel._queues`) y, al reconectar, restaura solo las que siguen vivas; en los tres servicios `queue` (y el canal, salvo en el chatbot) eran locales de `iniciar_consumidor()`. Reproducido en local y corregido reteniendo canal y cola a nivel de módulo (`_CHANNELS_VIVOS`, `_QUEUES_VIVAS`) en chatbot (`4c65a92`), proyeccion (`6a9494b`) y backend (`de0b224`, solo el consumer de persistencia; los clientes RPC abren canal y cola nuevos por petición y no lo necesitan). Cada repo trae `scripts/probar_reconexion_consumer.py` (recreate, restart y corte de red ×3 contra un RabbitMQ desechable).

Prueba final: un solo `docker compose up -d --force-recreate --no-deps rabbitmq` bajo el candado compartido, con definiciones y estado respaldados antes (en `/opt/techo360/backups`, permisos 600). Medido (t = segundos desde el comando, UTC 21:14:17):

| Hecho | t |
|---|---|
| Comando compose terminado; rabbitmq con ID nuevo (`8a19054f745e` → `e1bcbcb4f2d1`) | +3 s |
| Los 3 servicios reciben `CONNECTION_FORCED` y reintentan cada 5 s (`Connection refused` mientras el broker arranca) | +1 s |
| RabbitMQ abre el puerto 5672 (arranque de 71 s con `cpus: 0.2`) y acepta las 3 conexiones de backend, chatbot y proyeccion | +76 s |
| Healthcheck en `healthy` (visto por el sondeo; intervalo de 20 s) | +97 s |
| Nodo `rabbit@techo360-rabbitmq`: mismo directorio mnesia de antes (no se creó uno nuevo); `techo360` y `techo360-worker` con los mismos permisos, sin restaurar nada | +97 s a +115 s |
| `chatbot_requests`, `chatbot_eventos_persistencia` y `proyeccion_requests` con `consumer_count=1` | visto a +126 s (el sondeo estaba ocupado con los chequeos de persistencia; la conexión ya estaba aceptada desde +76 s) |
| Observación hasta +184 s: sin errores sostenidos (el último `Connection refused` fue a +71 s) | +184 s |

Los `consumer_tag` fueron idénticos a los de antes del recreate (los restauró aio-pika, no un consumer nuevo). Backend, chatbot, proyeccion y frontend conservaron el mismo ID y `RestartCount=0`; nadie reinició nada. `/health` dio 200 y `/api/zonas` 401 (no 502).

**Límites y deuda (alimentan T-126):**
- Una petición RPC en vuelo durante un corte pierde su cola de respuesta exclusiva y termina en timeout (hasta 200 s).
- La primera petición tras un `restart` de RabbitMQ puede fallar mientras el cliente reconecta; la siguiente responde (visto en las pruebas locales).
- `connect_robust` de arranque no reintenta: si el broker no está disponible al iniciar, el proceso termina y el contenedor entra en bucle de reinicios (visto con el worker local sin Tailscale).
- `deploy-infra.sh` no verifica que reaparezcan los consumers tras recrear RabbitMQ, y su `rabbitmqctl list_consumers ... priority` no funciona en RabbitMQ 3.13 (falla en silencio por el `|| true`).
- Quedan 7 directorios `rabbit@<id>` huérfanos en el volumen `rabbitmq_data` (de recreates anteriores al `hostname` fijo), sin limpiar.
- El `docker-compose.yml` solo pone `hostname` fijo a rabbitmq: el primer recreate con ese cambio (6-oct) sí arrancó con un nodo vacío; los siguientes ya conservan el estado.

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

## Presupuesto de recursos (propuesta del 9-oct-2026, NO desplegada)

Rama `feat/presupuesto-recursos`, apilada sobre `feat/recursos-vps-parte1` (PR #10). Desplegarla es el **paso 7** y necesita el «autorizo paso 7». Sustituye a la antigua «parte 2» de `cpuset`. Marcas: COMPROBADO = medido; HIPÓTESIS = inferido; «no verificado» = sin comprobar.

**Premisa.** Ollama solo trabaja cuando llega un mensaje. Cuando genera debe poder usar casi toda la CPU con prioridad; en reposo no debe retener recursos que otros necesitan.

**Cadena de prioridad real del chatbot (COMPROBADO en el código y en el log del 9-oct).** Los workers de laboratorio (`techo360-workers`, Ollama fuera de la VPS) consumen `chatbot_requests` con prioridad de consumidor **10**; el consumer del chatbot de la VPS tiene prioridad **0**; todos con `prefetch 1`. RabbitMQ entrega primero a los consumidores de mayor prioridad que estén libres y, mientras uno esté ocupado o desconectado, el mensaje va al siguiente. Consecuencias para el dimensionado:
- El Ollama de la VPS **no es «solo el último recurso»**: recibe todo lo que los workers no pueden tomar (todos ocupados, caídos o sin red). El 9-oct, con el worker caído, la VPS atendió 8 de 10 envíos.
- Por eso se dimensiona para atender la carga completa cuando haga falta (prioridad de CPU máxima, techo de memoria holgado sobre el pico medido), no como una reserva simbólica.
- Cuantos más workers estables haya, menos trabajo llega a la VPS, pero el diseño no debe depender de ello. VPS: 6 vCPU (Xeon E5-4669 v4, 1 hilo por núcleo), 11 GiB de RAM, 4 GiB de swap, sin GPU.

### CPU: prioridad en vez de cuotas ajustadas
- **Sin `cpuset`:** todos los contenedores usan los 6 núcleos.
- **`cpu_shares`:** solo decide el reparto cuando hay contención (en cgroup v2 Docker lo traduce a `cpu.weight`).
- **`cpus`:** es un tope holgado contra servicios desbocados, no una cuota ajustada.
- **Por qué:** con las cuotas antiguas (0,2–0,35) los Postgres pasaban ~36–39 % de sus periodos activos estrangulados (auditoría del 9-oct, COMPROBADO). Una consulta pesada de geometría se quedó clavada en su cuota el 67 % del tiempo.
- **Prueba local de contención** (COMPROBADO en local; host emulado de 6 núcleos con `cpuset 0-5`; mismo modelo base `llama3.2:3b` con id `a80c4f17acd5`; 1.104 polígonos de ~200 vértices; 20 clientes concurrentes con `pgbench`; mediana de 3 corridas). Las cifras absolutas no son las de la VPS (CPU distinta); solo vale la comparación.

| Escenario | p95 Postgres solo | p95 Postgres con Ollama generando | tok/s Ollama solo | tok/s Ollama con Postgres |
|---|---|---|---|---|
| Actual (pg 0,35, ollama 3 CPU) | 701 ms | 495 ms | 15,06 | 14,71 |
| Parte 1 (pg 0,75) | 295 ms | 207 ms | 15,00 | 14,45 |
| Este diseño, `num_thread` 3 | **94 ms** | **96 ms** | 15,35 | 14,42 |
| Este diseño, `num_thread` 4 | 94 ms | 79 ms | 16,23 | **14,92** |
| Este diseño, `num_thread` 5 | 93 ms | 91 ms (tps 598 → 432, máximos de 5,6–6,3 s) | 16,51 | **12,46** |

- **`num_thread`:** lo fija el chatbot (`NUM_THREAD = 3` en `app/ollama_client.py`, D11 del 5-oct: 4,91 → 7,46 tokens/s con `cpus=3`). Mientras siga en 3, Ollama no usa más de ~3 núcleos aunque su tope sea 5. Con 5 hilos se degrada bajo carga: llama.cpp sincroniza sus hilos, así que un hilo desplazado frena a todos. **Recomendación: 4**, pero solo después de medirlo en la VPS con `scripts/medir-presupuesto-recursos.sh --ollama`. Es un cambio del chatbot (no de este compose) y también afecta a los workers, que usan el mismo código.

### Memoria: techos, no reservas
Reglas:
- La suma de `mem_limit` no pasa de 9,5 GiB.
- `memswap_limit` = `mem_limit` (ningún contenedor usa swap).
- Cada techo es al menos el pico medido × 1,3.
- En Postgres, `mem_limit` > `shared_buffers` + `work_mem` × conexiones esperadas.

Los picos son `memory.peak` del cgroup desde el último arranque de cada contenedor (auditoría del 9-oct, COMPROBADO). Son ventanas cortas: no incluyen la ingesta semanal del backend ni carga real. Por eso los techos quedan por encima del pico × 1,3.

### Valores por contenedor
| Contenedor | `mem_limit` (antes → después) | Pico medido × 1,3 | `cpus` | `cpu_shares` | `oom_score_adj` | Razón |
|---|---|---|---|---|---|---|
| ollama | 3072m → **3328m** | 2,46 GiB → 3,2 GiB | 3.0 → **5.0** | 1024 → **4096** | 0 → **+500** | El modelo de 2,0 GB más contexto ya llegó al 82 % de 3 GiB. Mayor prioridad de CPU cuando genera; primero en morir ante un OOM (se recarga solo). |
| postgres-principal | 512m → **1024m** | 304 MiB → 395 MiB | 0.35 → **2.0** | **1024** | **−500** | PostGIS y la geometría de `/api/zonas`: el techo deja espacio a la caché de páginas (`shared_buffers` 128 MB, `work_mem` 4 MB, `max_connections` 100). Era el más estrangulado. No bajarlo hasta re-medir (ver «Cómo re-medir Postgres»). |
| backend | 512m → **896m** | 147 MiB → 191 MiB | 0.3 → **1.5** | **1024** | **−200** | API e ingesta semanal (no incluida en el pico medido). |
| postgres-vector | 512m → **512m** | 101 MiB → 131 MiB | 0.35 → **1.0** | **512** | **−500** | Conversaciones; preparado para el RAG futuro. |
| rabbitmq | 256m → **576m** | 256 MiB (= tope) → 333 MiB | 0.2 → **1.0** | **512** | **−200** | Watermark absoluto de 270 MiB (≤ 50 % del límite; Erlang puede pedir el doble al recolectar). Con 230 MiB, la carga de 2.000 × 4 KB llegaba al 79–85 % del watermark. |
| chatbot | 512m → **384m** | 45 MiB → 58 MiB | 0.3 → **1.0** | **512** | 0 | El modelo vive en ollama. |
| proyeccion | 512m → **256m** | 134 MiB → 174 MiB | 0.3 → **1.0** | **512** | 0 | Series de tiempo. |
| postgres-users | 256m → **256m** | 74 MiB → 96 MiB | 0.2 → **0.5** | **256** | **−500** | Lo usa cada login. |
| redis | 128m → **256m** | 21 MiB → 27 MiB | 0.15 → **0.5** | **256** | 0 | Caché de `/api/zonas` (cuerpo gzip) y OTP. |
| frontend | 128m → 128m | 9,4 MiB → 12 MiB | 0.15 → **0.5** | **256** | 0 | nginx estático. |
| **Suma** | 6,25 GiB → **7,44 GiB** | | | | | Quedan ~3,5 GiB para el SO, dockerd, Tailscale, los runners y la caché de página aunque todos llegaran a su techo a la vez (HIPÓTESIS: no ocurre). |

- **`memswap_limit` = `mem_limit` en todos:** antes Docker dejaba a cada contenedor usar en swap tanto como su `mem_limit` (6,25 GiB posibles frente a 4 GiB reales).
- **`oom_score_adj`:** Docker 29.8 lo aplica (`/proc/1/oom_score_adj` = 500, −500 y −200, COMPROBADO en local). En la VPS (29.7.2) queda «no verificado» hasta el despliegue.
- **`OLLAMA_KEEP_ALIVE`:** se fija explícito en `5m` (el valor por defecto, para que no dependa de la versión de la imagen). Un valor corto liberaría ~2,5 GiB en reposo, pero el primer mensaje pagaría la carga en frío: 5–12 s en la VPS (README, 5-oct) o 3,0–3,3 s en local (COMPROBADO) sobre ~46 s por mensaje. El presupuesto ya cabe con Ollama en su techo, así que acortarlo no mejora nada medible.

### Verificación
- `scripts/verificar-presupuesto-recursos.sh` lee `docker compose config` y falla si se rompe alguna de las 6 reglas: suma ≤ 9,5 GiB; watermark ≤ 50 %; `memswap` = `mem`; Ollama con el mayor `cpu_shares`; Ollama con `cpus` ≤ 5; Postgres con `oom_score_adj` < 0. Sobre la parte 1 falla; sobre esta rama pasa (suma 7,44 GiB; watermark 46,9 %).
- `scripts/medir-presupuesto-recursos.sh` es la medición C1 de solo lectura para la VPS. Con `--ollama` (solo con autorización) mide tok/s con 3, 4 y 5 hilos y la carga en frío.

### Pendiente de medir en la VPS (no se puede fuera de ella)
- Línea base real de Ollama: 7,18 tok/s; ~46 s por mensaje.
- El efecto de `num_thread` 4 y la carga en frío con el hardware real.
- Conexiones reales de cada Postgres (valores actuales medidos: `shared_buffers` 128 MB, `max_connections` 100, `work_mem` 4 MB).
- Los picos con la ingesta semanal (lunes 03:00 UTC).
- `oom_score_adj` en Docker 29.7.2.

### Cómo re-medir Postgres (antes de bajar sus techos)
Los techos de Postgres (1024m / 512m / 256m) son generosos a propósito: el pico medido (304 / 101 / 74 MiB) **no incluye** una ingesta semanal real. No bajarlos hasta tener una ingesta medida con los contenedores ya recreados (`memory.peak` se reinicia al recrear):
1. Esperar al lunes 03:00 UTC (ingesta) y medir pasados ~30 min: `scripts/medir-presupuesto-recursos.sh` (solo lectura) y, por contenedor, `docker exec <c> cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events` (campos `oom` y `oom_kill` deben seguir en 0).
2. Si `memory.peak × 1,3` cabe con holgura por debajo del techo actual durante 2 ingestas seguidas, proponer el nuevo techo en un PR aparte.

### Despliegue (paso 7) y subida en caliente del backend (paso 7a)
- `docs/runbook-paso-7a.md`: subir en caliente la memoria del backend de 512m a 896m (`docker update`), antes de la ingesta del lunes. No recrea nada.
- `docs/runbook-paso-7.md`: ventana nocturna para recrear los 10 contenedores con este presupuesto, en dos lotes, con criterio de aborto y reversa.

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

### R1: borrado de conversaciones de `usuario_id = 2`
- 11 conversaciones y 42 mensajes de `usuario_id = 2` borrados (2026-10-05, 16:12:05 UTC), con respaldo, copia en el PC, prueba de restauración local (15 de 15) y reversa. Quedaron las 5 conversaciones y 10 mensajes de `usuario_id = 0`; las secuencias no se tocaron (25 y 69).
- Respaldo fuera de la rotación: `/opt/techo360/backups/reset_conversaciones_20261005_160349/`.
  - `db_vector_completo.sql.gz`: 7484 B, sha256 `1876c8945cb39263cbcad19b62629d3f0d47d572bc6ccbab2ca9b6f3b542c0af`.
  - `conversaciones_mensajes_datos_COPY.sql.gz`: 6524 B, sha256 `466337fd4c61da8e6fb900d70399ef8a3b426e1cfc67771cd719f11a23feb0bb`.
  - Copia en el PC de trabajo (`respaldos-vps`) con tamaño y sha256 verificados antes del borrado.
- Prueba de restauración local: PostgreSQL 16.4 desechable (127.0.0.1:55436). Restaurar el dump completo (16 conversaciones y 52 mensajes), ejecutar la transacción exacta del borrado (quedan 5 y 10), restaurar solo las dos tablas desde el dump COPY (16 y 52, md5 idéntico) y comprobar que la guardia aborta si hay un mensaje en `procesando`: 15 comprobaciones, 0 fallos.
- Reversa: la misma secuencia del R3 (más abajo), apuntando a la carpeta de este respaldo.

### Error real de Ollama (R2d)
Inyección de fallo con un vigilante en el VPS (sesión de BD en solo lectura). Horas del vigilante, UTC, tal como las registró:
- 20:01:18.890: vigilante armado (ventana de 60 min, `id > 69`).
- 20:05:12.994: fila 70 en `procesando`, única en vuelo. Espera de 5 s.
- 20:05:18.491: temporizador de seguridad armado (`docker start` a los 45 s).
- 20:05:18.494: `docker stop techo360-ollama`. 20:05:18.870: Ollama detenido.
- 20:05:39.162: `docker start` (sin recrear). 20:05:39.700: `cpus=3000000000` y `/api/tags` en 200 con los 2 modelos.
- 20:05:39.903: el vigilante registra el mensaje 70 en `error` con `intentos = 1`. Es la hora en que retomó el sondeo, porque estaba bloqueado en la parada y la espera de 20 s; el cambio real fue hacia las 20:05:18,6 (aviso del chatbot a las 20:05:18.534 y 503 del backend a las 20:05:18.579).
- 20:06:17.602: tras pulsar Reintentar, el mensaje 70 pasa a `procesando` con `intentos = 2`.
- 20:07:04.093: el vigilante registra el mensaje 70 en `respondido` con `intentos = 2`, y la respuesta del asistente (id 71). En la base, `actualizado_en` es 20:07:03.435. Reintentar tardó ~46 s.

Qué ocurrió (COMPROBADO con los logs): Ollama se detuvo **durante la carga del modelo** (su log registra `Load failed` a las 20:05:18.584). El chatbot registró `Server disconnected without sending a response` y el backend devolvió **503** al usuario. El mensaje no se perdió: quedó en `error` y Reintentar lo llevó a `respondido` (~46 s, con carga en frío del modelo).

El caso de una respuesta tardía del primer intento no quedó probado: la parada cortó el primer intento durante la carga, así que no llegó ninguna respuesta tardía.

### D10 y D11: ventana sin consumer en `chatbot_requests`
- Al recrear el chatbot, la ventana sin consumer fue de ~3,1 s en ambos despliegues: 3,13 s en D10 y 3,11 s en D11, medida desde la muerte (`die`) del contenedor viejo hasta el registro del consumer nuevo (eventos de Docker y log del chatbot).
- Aviso: el reencolado de un mensaje en vuelo no se probó; en ninguno de los dos despliegues había mensajes en curso.

### Estrés, niveles 1 y 2
- Nivel 1, 1 mensaje: 43,6 s (la base da 43,7 s entre el mensaje de usuario y la respuesta; 195 tokens a ~4,6 tokens/s).
- Nivel 2, 2 mensajes simultáneos (de la base): 39,3 s y 80,2 s. El segundo esperó ~39 s al primero y tardó ~41 s propios.
- Se atiende en serie: el consumer del chatbot usa `prefetch 1` y la cola mostró 2 mensajes con 1 sin ack.
- Los niveles 3 y 4 están en la sección siguiente.

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

### R3: borrado de conversaciones de prueba
- 11 conversaciones de prueba y 22 mensajes borrados (ids 26–36, `usuario_id = 2`), con respaldo, copia en el PC, reversa documentada y secuencias intactas (`conversaciones_id_seq` en 36 y `mensajes_id_seq` en 91).
- Quedan las 5 conversaciones y 10 mensajes de `usuario_id = 0`.
- Antes de borrar se comprobó, con consultas de solo lectura, que el conjunto `id > 25` eran exactamente esas 11 conversaciones, todas de `usuario_id = 2`, con mensajes que empiezan por «Prueba R2c» o «Estres N», y 0 mensajes en `pendiente`/`procesando`. La transacción repite esas comprobaciones y aborta si no coinciden.
- Respaldo fuera de la rotación: `/opt/techo360/backups/reset_conversaciones_r3_20261005_213501/` (`db_vector_completo.sql.gz` y `conversaciones_mensajes_datos_COPY.sql.gz`, con `gzip -t` y `SHA256SUMS`). Copia en el PC de trabajo (`respaldos-vps`) con tamaño y sha256 verificados antes del borrado.
- Lección: al validar patrones de contenido conviene un indicador no ambiguo. La `N` de «Estres N» se interpretó primero como un número y marcó 10 conversaciones como «sin patrón» por error.

**Reversa** (solo las dos tablas, en una transacción; usa el `psql` del contenedor, de la misma versión que el `pg_dump`). En el VPS:

```bash
cd /opt/techo360/backups/reset_conversaciones_r3_20261005_213501
set -a; source /opt/techo360/techo360-infra/.env; set +a    # no imprimir el contenido
{ echo "BEGIN;"; echo "DELETE FROM conversaciones;"; zcat conversaciones_mensajes_datos_COPY.sql.gz; echo "COMMIT;"; } \
  | docker exec -i techo360-postgres-vector psql -U "$DB_VECTOR_USER" -d "$DB_VECTOR_NAME" -v ON_ERROR_STOP=1
```

Devuelve las 16 conversaciones y 32 mensajes anteriores al borrado (`DELETE FROM conversaciones` cascada a `mensajes`) y deja las secuencias en 36 y 91. Antes de restaurar, avisar a quien use TechoBot. Esta secuencia (`BEGIN`, `DELETE`, dump de datos, `COMMIT`) se validó en una base PostgreSQL desechable en el R1 de ese mismo día; en R3 no se repitió esa prueba, y no se probó en el VPS con las órdenes `\restrict` y `\unrestrict` que emite el `pg_dump` actual.

<!-- prueba CI/CD -->
