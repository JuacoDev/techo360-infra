#!/usr/bin/env bash
# Medicion del presupuesto de recursos de la VPS (paso C1). Se ejecuta DESDE EL PC,
# sin copiar nada a la VPS:
#   gh api "repos/JuacoDev/techo360-infra/contents/scripts/medir-presupuesto-recursos.sh?ref=feat/presupuesto-recursos" \
#     -H "Accept: application/vnd.github.raw" | ssh techo360-admin@207.248.81.115 'bash -s' > medicion-c1.txt
#
# Por defecto es SOLO LECTURA: no recrea, no reinicia, no escribe en ninguna BD
# (sesiones con default_transaction_read_only = on) y no imprime variables de entorno
# (de Ollama solo las OLLAMA_*, filtradas en la propia VPS).
#
# Opcion --ollama (SOLO con autorizacion explicita de Juan): mide tokens/s de Ollama
# con num_thread 3, 4 y 5 y la carga en frio del modelo, llamando a la API de Ollama
# desde el contenedor del chatbot con un prompt neutro FIJO (no pasa por el chatbot ni
# por la BD). Genera carga de CPU durante ~2-4 min y descarga el modelo una vez
# (`keep_alive: 0`), asi que el siguiente mensaje real pagaria la carga en frio:
#   ... | ssh techo360-admin@207.248.81.115 'bash -s -- --ollama' > medicion-c1-ollama.txt
set -u
MEDIR_OLLAMA=0; [ "${1:-}" = "--ollama" ] && MEDIR_OLLAMA=1
MUESTRAS=${MUESTRAS:-6}; ESPERA=${ESPERA:-20}
CONT="techo360-frontend techo360-backend techo360-chatbot techo360-proyeccion techo360-ollama techo360-rabbitmq techo360-redis techo360-postgres-principal techo360-postgres-vector techo360-postgres-users"
seccion() { printf '\n==================== %s ====================\n' "$1"; }

seccion "1. Host"
date -u '+ahora (UTC): %Y-%m-%d %H:%M:%S'
echo "nproc: $(nproc)"; free -h; echo "-- swap"; cat /proc/swaps; echo "swappiness: $(cat /proc/sys/vm/swappiness)"; uptime
docker version --format 'docker {{.Server.Version}}'; docker compose version --short 2>/dev/null | sed 's/^/compose /'

seccion "2. Limites por contenedor (docker inspect, campos concretos)"
for c in $CONT; do
  docker inspect --format '{{.Name}} Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} NanoCpus={{.HostConfig.NanoCpus}} CpusetCpus="{{.HostConfig.CpusetCpus}}" CpuShares={{.HostConfig.CpuShares}} OomScoreAdj={{.HostConfig.OomScoreAdj}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}} desde={{.State.StartedAt}}' "$c" 2>&1
done

seccion "3. Picos y throttling acumulados desde el arranque (cgroup v2)"
for c in $CONT; do
  id=$(docker inspect --format '{{.Id}}' "$c" 2>/dev/null) || continue
  d=/sys/fs/cgroup/system.slice/docker-$id.scope
  echo "$c | peak=$(cat $d/memory.peak 2>/dev/null) | $(tr '\n' ' ' < $d/memory.events 2>/dev/null) | $(grep -E 'usage_usec|nr_periods|nr_throttled|throttled_usec' $d/cpu.stat 2>/dev/null | tr '\n' ' ')"
done

seccion "4. docker stats en reposo ($MUESTRAS muestras cada $ESPERA s)"
for i in $(seq 1 "$MUESTRAS"); do
  echo "-- muestra $i $(date -u +%T) load=$(cut -d' ' -f1-3 /proc/loadavg)"
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}'
  [ "$i" -lt "$MUESTRAS" ] && sleep "$ESPERA"
done

seccion "5. Ollama: modelos residentes y variables OLLAMA_* (solo esas)"
docker exec techo360-ollama ollama ps < /dev/null
docker exec techo360-ollama ollama list < /dev/null
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' techo360-ollama | grep '^OLLAMA_' || true
echo "(si OLLAMA_KEEP_ALIVE / OLLAMA_NUM_PARALLEL / OLLAMA_MAX_LOADED_MODELS no aparecen, rigen los valores por defecto de Ollama)"

seccion "6. OOM del kernel (dmesg y journal sin sudo; puede no estar permitido)"
dmesg 2>&1 | grep -iE 'oom|killed process' | tail -10 || true
journalctl -k --since '30 days ago' --no-pager 2>&1 | grep -iE 'oom|killed process' | tail -10 || echo '(sin coincidencias o sin acceso)'

seccion "7. Postgres: parametros de memoria, conexiones y tamano (sesion READ ONLY)"
for c in techo360-postgres-principal techo360-postgres-vector techo360-postgres-users; do
  echo "-- $c"
  docker exec "$c" sh -c 'psql -X -q -At -F" | " -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SET default_transaction_read_only = on" -c "SHOW default_transaction_read_only" -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('"'"'shared_buffers'"'"', '"'"'max_connections'"'"', '"'"'work_mem'"'"', '"'"'maintenance_work_mem'"'"', '"'"'effective_cache_size'"'"') ORDER BY name" -c "SELECT '"'"'conexiones_actuales'"'"', count(*) FROM pg_stat_activity WHERE datname = current_database()" -c "SELECT '"'"'tamano_bd'"'"', pg_size_pretty(pg_database_size(current_database()))"' < /dev/null
done

seccion "8. RabbitMQ: memoria real frente al watermark"
docker exec -u rabbitmq techo360-rabbitmq rabbitmq-diagnostics -q status < /dev/null 2>/dev/null | grep -iE 'Total memory used|watermark|Calculation strategy|Erlang configuration'
docker exec -u rabbitmq techo360-rabbitmq rabbitmq-diagnostics -q alarms < /dev/null 2>/dev/null | tail -1

if [ "$MEDIR_OLLAMA" = 1 ]; then
  seccion "9. Ollama: tokens/s con num_thread 3, 4 y 5 y carga en frio (opcion --ollama)"
  MODELO=$(docker exec techo360-ollama ollama list < /dev/null | awk 'NR > 1 && /techo360-chatbot/ { print $1; exit }')
  echo "modelo: $MODELO"
  docker exec -i techo360-chatbot python - "$MODELO" <<'PY'
# Prompt neutro y fijo; no toca el chatbot ni la BD. Mide con la API de Ollama.
import json, sys, time, urllib.request
URL = "http://ollama:11434/api/generate"
MODELO = sys.argv[1]
PROMPT = "Explica en un parrafo que es un indicador de deficit habitacional."

def generar(hilos, keep_alive="5m"):
    cuerpo = {"model": MODELO, "prompt": PROMPT, "stream": False, "keep_alive": keep_alive,
              "options": {"num_thread": hilos, "num_predict": 160, "temperature": 0, "seed": 1}}
    t0 = time.time()
    req = urllib.request.Request(URL, json.dumps(cuerpo).encode(), {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=300))
    return {"hilos": hilos, "pared_s": round(time.time() - t0, 1),
            "carga_s": round(r.get("load_duration", 0) / 1e9, 2),
            "tokens": r.get("eval_count"),
            "tok_s": round(r["eval_count"] / (r["eval_duration"] / 1e9), 2) if r.get("eval_duration") else None}

# Carga en frio: descargar el modelo y medir la primera peticion.
urllib.request.urlopen(urllib.request.Request(URL, json.dumps({"model": MODELO, "keep_alive": 0}).encode(),
                                              {"Content-Type": "application/json"}), timeout=120).read()
time.sleep(3)
print("frio", generar(3))
for hilos in (3, 4, 5, 3):
    for intento in (1, 2):
        print("caliente", generar(hilos))
PY
fi

seccion "FIN"
