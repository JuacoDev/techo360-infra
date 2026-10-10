#!/usr/bin/env bash
# Verifica el presupuesto de recursos del docker-compose.yml SIN levantar nada:
# lee `docker compose config` (sin interpolar variables, no necesita .env) y
# rabbitmq/20-techo360.conf, y falla (exit 1) si se rompe alguna regla:
#   1. suma de mem_limit > 9,5 GiB
#   2. watermark absoluto de rabbitmq > 50 % de su mem_limit
#   3. algun servicio sin memswap_limit = mem_limit
#   4. ollama no tiene el mayor cpu_shares (estrictamente)
#   5. ollama con cpus > 5.0
#   6. algun postgres sin oom_score_adj negativo
# Uso (desde cualquier carpeta): scripts/verificar-presupuesto-recursos.sh
# Ver README, seccion «Presupuesto de recursos», para el porque de cada valor.
set -euo pipefail
cd "$(dirname "$0")/.."

PY=$(command -v python3 || command -v python || true)
[ -n "$PY" ] || { echo "ERROR: hace falta python3 para leer el JSON de docker compose" >&2; exit 2; }

CONFIG_JSON=$(docker compose -f docker-compose.yml config --no-interpolate --format json 2>/dev/null) \
  || { echo "ERROR: docker compose config fallo (sintaxis del compose)" >&2; exit 2; }
export CONFIG_JSON

"$PY" - <<'PY'
import json
import os
import re
import sys

LIMITE_SUMA_GIB = 9.5
servicios = json.loads(os.environ["CONFIG_JSON"])["services"]


def a_bytes(valor):
    """'896m', '4g' o un entero -> bytes (unidades binarias, como Docker)."""
    if valor is None:
        return None
    if isinstance(valor, (int, float)):
        return int(valor)
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([bkmg]?)b?", str(valor).strip().lower())
    if not m:
        raise SystemExit("valor de memoria no reconocido: %s" % valor)
    return int(float(m.group(1)) * {"": 1, "b": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[m.group(2)])


fallos = []
print("%-20s %10s %10s %5s %6s %7s" % ("servicio", "mem_limit", "memswap", "cpus", "shares", "oom_adj"))
suma = 0
for nombre in sorted(servicios):
    s = servicios[nombre]
    mem, swap = a_bytes(s.get("mem_limit")), a_bytes(s.get("memswap_limit"))
    print("%-20s %10s %10s %5s %6s %7s" % (nombre, s.get("mem_limit"), s.get("memswap_limit"),
                                           s.get("cpus"), s.get("cpu_shares"), s.get("oom_score_adj")))
    if mem is None:
        fallos.append("%s: sin mem_limit" % nombre)
        continue
    suma += mem
    if swap != mem:
        fallos.append("%s: memswap_limit (%s) distinto de mem_limit (%s)" % (nombre, s.get("memswap_limit"), s.get("mem_limit")))

# 1. suma de techos
suma_gib = suma / 1024 ** 3
print("\nsuma de mem_limit: %.2f GiB (tope %.1f GiB)" % (suma_gib, LIMITE_SUMA_GIB))
if suma_gib > LIMITE_SUMA_GIB:
    fallos.append("suma de mem_limit %.2f GiB > %.1f GiB" % (suma_gib, LIMITE_SUMA_GIB))

# 2. watermark de rabbitmq <= 50 % de su mem_limit (Erlang puede pedir el doble al recolectar)
conf = open("rabbitmq/20-techo360.conf", encoding="utf-8").read()
m = re.search(r"^vm_memory_high_watermark\.absolute\s*=\s*(\d+)\s*MiB\s*$", conf, re.M)
if not m:
    fallos.append("rabbitmq/20-techo360.conf: falta vm_memory_high_watermark.absolute en MiB")
else:
    wm = int(m.group(1)) * 1024 ** 2
    mem_rmq = a_bytes(servicios["rabbitmq"].get("mem_limit"))
    print("watermark rabbitmq: %s MiB = %.1f %% de su mem_limit (tope 50 %%)" % (m.group(1), 100.0 * wm / mem_rmq))
    if wm > 0.5 * mem_rmq:
        fallos.append("rabbitmq: watermark > 50 % de su mem_limit")

# 4 y 5. ollama: mayor prioridad de CPU y tope de 5 CPU (siempre queda >= 1 nucleo libre)
shares = {n: int(s.get("cpu_shares") or 1024) for n, s in servicios.items()}  # 1024 = valor por defecto de Docker
mayor_otro = max(v for n, v in shares.items() if n != "ollama")
if shares.get("ollama", 0) <= mayor_otro:
    fallos.append("ollama: cpu_shares %s no es el mayor (otro servicio tiene %s)" % (shares.get("ollama"), mayor_otro))
if float(servicios["ollama"].get("cpus") or 0) > 5.0:
    fallos.append("ollama: cpus %s > 5.0" % servicios["ollama"].get("cpus"))

# 6. los postgres son los ultimos que el kernel debe matar
for nombre, s in sorted(servicios.items()):
    if nombre.startswith("postgres") and int(s.get("oom_score_adj") or 0) >= 0:
        fallos.append("%s: oom_score_adj %s (debe ser negativo)" % (nombre, s.get("oom_score_adj")))

if fallos:
    print("\nFALLA:")
    for f in fallos:
        print("  - " + f)
    sys.exit(1)
print("\nOK: el presupuesto cumple las 6 reglas.")
PY
