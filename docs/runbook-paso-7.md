# Runbook paso 7 — aplicar el presupuesto de recursos (ventana nocturna)

**NO ejecutar sin la frase literal de Juan: «autorizo paso 7»**, y solo dentro de una ventana acordada (madrugada; nunca lunes 02:30–04:30 UTC, que es la ingesta). Prerrequisito: paso 7a ya aplicado o incluido (el backend queda en 896m igualmente).

## Qué cambia (COMPROBADO con `docker compose up -d --dry-run` contra la VPS, 9-oct)
El compose de este PR **recrea los 10 contenedores**: `memswap_limit`, `cpus`, `cpu_shares`, `oom_score_adj` y `mem_limit` son parte de la configuración que compose compara. Con el compose de producción actual (c88e518) la misma simulación marca los 10 como «Running» (0 recreaciones).

## Por qué NO se hace con un simple merge
Un push a `development` dispara `deploy-infra.yml` → `deploy-infra.sh` → `docker compose up -d`, que recrea **los 10 a la vez** (Postgres incluidos) sin verificación intermedia. Para hacerlo en dos lotes se aplica **primero a mano** (misma configuración exacta) y **después** se fusiona: el deploy automático encuentra todo ya igual y no recrea nada (solo hace su respaldo habitual).

## 0. Preparación (antes de la ventana, solo lectura)
```bash
bash scripts/verificar-presupuesto-recursos.sh           # en el PC: debe terminar «OK … 6 reglas»
ssh techo360-admin@207.248.81.115
free -m; docker ps --format '{{.Names}} {{.Status}}' ; df -h /opt/techo360/backups | tail -1   # >= 2 GiB disponibles, 10 contenedores arriba, espacio para 3 dumps
docker exec techo360-rabbitmq rabbitmqctl list_consumers consumer_tag,queue_name,priority,active  # anotar quién consume chatbot_requests (workers prioridad 10, VPS 0)
docker exec techo360-rabbitmq rabbitmqctl list_queues name messages consumers   # colas vacías (si no, esperar)
```
Avisar a Juan/Daniel/MSoto de la ventana (el chatbot y los logins se cortan unos segundos).

## 1. Respaldo previo, fuera de la rotación
`backup-db.sh` conserva solo los 2 últimos dumps por base; hay que copiarlos a una subcarpeta propia:
```bash
flock -w 1800 /opt/techo360/logs/.deploy.lock /opt/techo360/techo360-infra/scripts/backup-db.sh
D=/opt/techo360/backups/paso7-$(date +%Y%m%d_%H%M); mkdir -p "$D"; umask 077
for p in principal vector usuarios; do cp "$(ls -1t /opt/techo360/backups/db_${p}_*.sql.gz | head -1)" "$D/"; done
gzip -t "$D"/*.sql.gz && echo GZIP_OK
sha256sum "$D"/*.sql.gz | tee "$D/SHA256SUMS"
```
Copiar los 3 al PC (`scp`), comparar `sha256sum` allí y confirmar **antes** de seguir. Sin copia verificada → no seguir.

## 2. Poner la VPS en la configuración del PR (sin recrear nada todavía)
```bash
cd /opt/techo360/techo360-infra
git fetch origin && git checkout --detach origin/feat/presupuesto-recursos   # el SHA exacto del PR; anotarlo
docker compose up -d --dry-run 2>&1 | grep -E "Recreate$|Running$" | sort | uniq -c   # esperado: 10 «Recreate»
```
(`deploy-infra.sh` hace `git checkout development && git reset --hard origin/development`, así que esto se corrige solo en el siguiente deploy.)
Todos los comandos de recreación van con el candado compartido: `flock -w 1800 /opt/techo360/logs/.deploy.lock docker compose up -d --no-deps <servicio>`.

## 3. Lote 1 — servicios sin estado propio (uno por uno; verificar entre cada uno)
Orden: `frontend` → `proyeccion` → `chatbot` → `backend` → `ollama` → `redis`. (`ollama`: el modelo vive en el volumen `ollama_data`, la primera petición paga la carga en frío de 5–12 s. `redis`: caché de `/api/zonas` y OTP; los OTP vigentes se pierden, se piden de nuevo.)

Verificación tras **cada** contenedor `<c>`:
```bash
docker inspect -f '{{.Name}} {{.State.Status}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}} mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} cpus_nano={{.HostConfig.NanoCpus}} shares={{.HostConfig.CpuShares}} oom_adj={{.HostConfig.OomScoreAdj}}' techo360-<c>
docker logs --since 2m techo360-<c> 2>&1 | grep -ciE "error|traceback|fatal|killed"     # 0 (o solo los esperados al arrancar)
docker exec techo360-backend python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/health',timeout=5).read())"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/                                    # 200 (frontend)
docker exec techo360-rabbitmq rabbitmqctl list_consumers consumer_tag,queue_name,priority,active   # el consumer del chatbot (prioridad 0) vuelve tras recrear chatbot
```
Valores esperados de `inspect` (README «Valores por contenedor»): ollama 3328m/4096 shares/+500; backend 896m/1024/−200; chatbot 384m/512; proyeccion 256m/512; redis 256m/256; frontend 128m/256.
Tras `backend`: probar login y un `GET /api/zonas` desde el navegador (Juan). Tras `ollama`: un mensaje al chatbot de punta a punta (una sola vez; es carga real).

**Pausa de 10 min tras el lote 1:** `docker stats --no-stream`, `free -m`, `dmesg`/`journalctl -k | grep -i oom` sin eventos nuevos.

## 4. Lote 1b — RabbitMQ (tiene estado: colas)
Solo con colas vacías (§0). `flock … docker compose up -d --no-deps rabbitmq`. Esperar `healthy` (~10 s de mediana medida en local, hasta 60 s). Verificar: watermark leído de la configuración real (`docker exec techo360-rabbitmq rabbitmqctl status | grep -A1 -i "memory high watermark"` → 283115520 bytes = 270 MiB), `oom_adj=-200`, `mem=603979776`.
**Riesgo conocido (T-127):** los consumers pueden no reconectar tras recrear RabbitMQ. Comprobar `list_consumers`: deben aparecer el chatbot de la VPS (prioridad 0) **y los workers externos** (prioridad 10). Si falta alguno, `docker restart techo360-chatbot` y avisar a Juan para reiniciar el worker de su PC.

## 5. Lote 2 — Postgres, uno por uno, al final
Orden: `postgres-users` → `postgres-vector` → `postgres-principal` (el más crítico, el último). El respaldo del §1 debe tener < 1 h; si no, repetirlo.
Cada uno se recrea sobre su volumen (datos intactos). Tras cada uno:
```bash
docker inspect -f '{{.State.Status}} {{.State.Health.Status}} oomkilled={{.State.OOMKilled}} mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} oom_adj={{.HostConfig.OomScoreAdj}}' techo360-postgres-<x>   # running healthy … oom_adj=-500
docker exec techo360-postgres-<x> psql -U <usuario> -d <bd> -Atc "select count(*) from pg_stat_activity"            # responde
```
Datos: contar filas de una tabla clave **antes y después** (solo conteos; p. ej. `mapcalordb` y `conversaciones`) y comparar con los conteos tomados en §0.
Después de los tres: `docker restart techo360-backend techo360-chatbot techo360-proyeccion` **solo si** los logs muestran conexiones caídas (el pool no se rehace solo); si no, no tocarlos.

## 6. Cierre
```bash
bash scripts/medir-presupuesto-recursos.sh                      # solo lectura (sin --ollama): peaks y OOM desde cero
docker compose up -d --dry-run 2>&1 | grep -c Running           # 10: la VPS coincide con el compose del PR
```
Entonces (y solo entonces) fusionar el PR a `development`: el deploy automático hará su respaldo y un `up -d` sin recreaciones (confirmar en el log del run: «Running» ×10). Aplicar en el mismo paso el texto de `CLAUDE.md` (punto 3 de «Restricciones reales») propuesto en la descripción del PR.

## Criterio de aborto (parar y no seguir al siguiente contenedor)
- Un contenedor no queda `running`/`healthy` en 120 s, o se reinicia (`RestartCount` sube).
- `/health` del backend distinto de `healthy`, o el frontend distinto de 200 durante > 60 s.
- Aparecen `OOMKilled=true` o eventos OOM nuevos en `journalctl -k`.
- `free -m` con `available` < 1,5 GiB o swap en uso creciente.
- RabbitMQ sin consumers de `chatbot_requests` tras `restart` del chatbot.
- Conteos de filas distintos antes/después en cualquier Postgres.

## Rollback
Por contenedor (el mismo orden inverso: Postgres solo si es imprescindible):
```bash
cd /opt/techo360/techo360-infra && git checkout --detach c88e518          # compose y rabbitmq/20-techo360.conf de producción
flock -w 1800 /opt/techo360/logs/.deploy.lock docker compose up -d --no-deps <servicio>
```
- Recrear con c88e518 devuelve `mem_limit`/`cpus` anteriores, `oom_score_adj` = 0 y el watermark/`.conf` anterior de RabbitMQ: **`oom_score_adj` y el `.conf` de RabbitMQ solo se revierten recreando.**
- Si solo hay que bajar o subir un techo de memoria sin recrear: `docker update --memory <X> --memory-swap <X> techo360-<c>` (no cambia `oom_score_adj` ni `cpu_shares` estructurales; `docker update --cpu-shares` sí existe). Valores anteriores: ollama 3072m, postgres-principal 512m, postgres-vector 512m, postgres-users 256m, redis 128m, rabbitmq 256m, backend 512m, chatbot 512m, proyeccion 512m, frontend 128m.
- Datos: no se espera restaurar nada (los volúmenes no se tocan). Si una BD queda corrupta: restaurar el dump de `paso7-…` con el `psql` **del propio contenedor** (los dumps traen `\restrict`/`\unrestrict`).
- Tras el rollback, `git checkout development && git reset --hard origin/development` y, si el PR ya se fusionó, `git revert -m 1 <SHA del merge>` en `development`.
