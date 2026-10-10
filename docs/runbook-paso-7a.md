# Runbook paso 7a — subir en caliente la memoria del backend (512m → 896m)

**NO ejecutar sin la frase literal de Juan: «autorizo paso 7a».** Debe estar hecho **antes del lunes 12-oct-2026 03:00 UTC (domingo 22:00 Bogotá)**: la ingesta semanal corre en el backend y el único OOM del kernel en 30 días (28-sep 03:03 UTC) fue ahí, con el límite de 512 MiB.

Qué hace: cambia el límite del cgroup del contenedor **en caliente**. No recrea ni reinicia el contenedor, no corta conexiones, no toca otros servicios, no escribe en ninguna BD.

## Por qué es seguro (COMPROBADO)
- **`docker compose up -d` (y `deploy-infra.sh`, que lo ejecuta) no lo revierte ni recrea el contenedor.** Compose decide recrear comparando el hash de la *configuración del compose* guardado en una etiqueta del contenedor, no el límite vivo. Prueba local (Docker Compose v5.5.1): contenedor con `mem_limit: 64m` → `docker update --memory 96m --memory-swap 96m` → `up -d`, `up -d --dry-run` y `up -d --remove-orphans` → mismo ID de contenedor y el límite sigue en 96m. En la VPS, `docker compose up -d --dry-run` con el compose de producción (c88e518) marca los 10 servicios como «Running» (0 recreaciones).
- **El compose del PR #12 pone el mismo valor** (`mem_limit: 896m`, `memswap_limit: 896m`). Cuando se despliegue el paso 7 el backend se recreará (como los otros 9) con 896m: el valor vivo y el declarado coinciden.
- **Trampa:** el compose del **PR #10** (parte 1) deja el backend en `512m`. Si #10 se fusiona a `development` *antes* que #12 y corre `deploy-infra`, el backend se recrea con 512m y se pierde el 7a. #12 está apilado sobre #10: fusionar #12 incluye #10. No fusionar #10 solo.
- Recrear el backend por cualquier otro motivo (`deploy-service.sh backend`, un push a `development` del backend) lo recrea con los valores del compose en producción (512m) → **tras cada deploy del backend, antes de paso 7, repetir el `docker update`**. (HIPÓTESIS razonada: `deploy-service.sh` usa `up -d --no-deps backend` con el compose del disco.)

## 1. Verificación previa (solo lectura)
```bash
ssh techo360-admin@207.248.81.115
docker inspect -f 'mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}} status={{.State.Status}}' techo360-backend
free -m            # columna «available» >= 2048 (subir 384 MiB de techo no reserva nada: es un tope)
docker compose -f /opt/techo360/techo360-infra/docker-compose.yml up -d --dry-run 2>&1 | grep -c Running   # 10 = nada que recrear
date -u            # confirmar que no es lunes 03:00 UTC ±10 min (ventana de la ingesta)
```
Esperado (medido el 9-oct 16:45 UTC): `mem=536870912 swap=1073741824 restarts=0 oomkilled=false status=running`; `available` ≈ 9,8 GiB.
Abortar si: `status` ≠ running, `RestartCount` > 0 sin explicación, o `available` < 2048 MiB.

## 2. Aplicar (solo con «autorizo paso 7a»)
```bash
docker update --memory 896m --memory-swap 896m techo360-backend
```
Los dos valores van juntos: `--memory-swap` debe ser ≥ `--memory`, y 896m = «sin swap extra» (coherente con `memswap_limit = mem_limit` del PR #12).

## 3. Verificación posterior
```bash
docker inspect -f 'mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} restarts={{.RestartCount}} started={{.State.StartedAt}}' techo360-backend
#   esperado: mem=939524096 swap=939524096 restarts=0 y StartedAt SIN cambios respecto a la verificación previa (no hubo reinicio)
docker exec techo360-backend python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/health',timeout=5).read())"
#   esperado: {"status":"healthy"...}
docker stats --no-stream techo360-backend      # la columna LIMIT debe decir ~896MiB
docker logs --since 5m techo360-backend 2>&1 | grep -ciE "error|traceback|killed"   # esperado 0 líneas nuevas
docker compose -f /opt/techo360/techo360-infra/docker-compose.yml up -d --dry-run 2>&1 | grep -c Running   # sigue en 10
```

## 4. Rollback
```bash
docker update --memory 512m --memory-swap 512m techo360-backend
```
Si el uso actual supera 512m, Docker rechaza el cambio (no mata nada): en ese caso reiniciar el backend (`docker restart techo360-backend`) y repetir. Normalmente en reposo usa ~150 MiB.

## 5. Seguimiento
- Lunes 12-oct ~03:30 UTC (solo lectura): `docker inspect -f '{{.RestartCount}} {{.State.OOMKilled}}' techo360-backend` y `docker exec techo360-backend cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events` → pico de la ingesta y `oom_kill 0`. Ese pico es el dato que faltaba para el techo definitivo.
