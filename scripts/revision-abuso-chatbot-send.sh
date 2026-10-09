#!/usr/bin/env bash
# Revision de abuso de POST /chatbot/send (expuesto por nginx sin autenticacion
# hasta el hotfix). SOLO LECTURA y SOLO CONTEOS: nunca imprime el texto de los
# mensajes, ni correos, ni nombres, ni IPs completas, ni variables de entorno.
#
# Se ejecuta DESDE EL PC de trabajo, sin copiar nada a la VPS:
#   ssh techo360-admin@207.248.81.115 'bash -s' < scripts/revision-abuso-chatbot-send.sh
# o, sin cambiar de rama en el checkout local:
#   gh api "repos/JuacoDev/techo360-infra/contents/scripts/revision-abuso-chatbot-send.sh?ref=chore/revision-abuso-chatbot-send" \
#     -H "Accept: application/vnd.github.raw" | ssh techo360-admin@207.248.81.115 'bash -s'
#
# Que hace (todo de lectura):
#   1. Ventana de evidencia: desde cuando existen los logs de cada contenedor
#      (docker logs se pierde al recrear el contenedor) y el driver de logs.
#   2. nginx (techo360-frontend): peticiones a /chatbot/send por dia, metodo y
#      codigo; IP agrupada en /24; user-agent (recortado); picos por hora en /chatbot/*.
#   3. chatbot (uvicorn): POST /chatbot/send por dia y codigo.
#   4. backend: errores del consumer de 'chatbot_eventos_persistencia'.
#   5. RabbitMQ: estado de la cola chatbot_eventos_persistencia.
#   6. postgres-vector: conteos de indicadores, en transaccion READ ONLY.
set -u
# OJO: con `bash -s < script`, cualquier comando que lea stdin se traga el resto del
# script. Por eso los docker exec que no necesitan entrada llevan `< /dev/null`.
F=techo360-frontend; C=techo360-chatbot; B=techo360-backend; R=techo360-rabbitmq
V=techo360-postgres-vector; U=techo360-postgres-users

seccion() { printf '\n==================== %s ====================\n' "$1"; }

seccion "0. Contexto"
date -u '+ahora (UTC): %Y-%m-%d %H:%M:%S'
for c in $F $C $B $R $V $U; do
  docker inspect --format '{{.Name}} creado={{.Created}} iniciado={{.State.StartedAt}} logs={{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}' "$c"
done

seccion "1. nginx: /chatbot/send (dia, metodo, codigo)"
# nginx:alpine envia access.log a stdout (= docker logs). Formato 'combined'.
docker logs "$F" 2>/dev/null | awk '
  $7 ~ /^\/chatbot\/send/ {
    split($4, t, ":"); dia = substr(t[1], 2); metodo = substr($6, 2)
    n[dia " " metodo " " $9]++
  }
  END { if (length(n) == 0) print "(ninguna peticion a /chatbot/send en la ventana de logs)"; for (k in n) print k, n[k] }' | sort

seccion "1b. nginx: /chatbot/send por IP agrupada (/24) y por user-agent (top 10)"
docker logs "$F" 2>/dev/null | awk '$7 ~ /^\/chatbot\/send/ { split($1, o, "."); print o[1] "." o[2] "." o[3] ".0/24" }' | sort | uniq -c | sort -rn | head -10
docker logs "$F" 2>/dev/null | awk -F'"' '$2 ~ /\/chatbot\/send/ { print substr($6, 1, 60) }' | sort | uniq -c | sort -rn | head -10

seccion "1c. nginx: /chatbot/* por hora (top 10 horas = picos) y total por dia"
docker logs "$F" 2>/dev/null | awk '$7 ~ /^\/chatbot\// { split($4, t, ":"); print substr(t[1], 2) " " t[2] "h" }' | sort | uniq -c | sort -rn | head -10
docker logs "$F" 2>/dev/null | awk '$7 ~ /^\/chatbot\// { split($4, t, ":"); print substr(t[1], 2) }' | sort | uniq -c

seccion "1d. nginx: otras rutas del servicio chatbot expuestas (docs/openapi/health)"
docker logs "$F" 2>/dev/null | awk '$7 ~ /^\/chatbot\/(docs|redoc|openapi\.json|health)/ { print $6 " " $7 " " $9 }' | sed 's/"//' | sort | uniq -c

seccion "2. chatbot (uvicorn): POST /chatbot/send por dia y codigo"
docker logs -t "$C" 2>&1 | awk '/"POST \/chatbot\/send/ { dia = substr($1, 1, 10); for (i = 1; i <= NF; i++) if ($i ~ /^HTTP\//) cod = $(i + 1); n[dia " " cod]++ }
  END { if (length(n) == 0) print "(ninguna)"; for (k in n) print k, n[k] }' | sort

seccion "3. backend: consumer de chatbot_eventos_persistencia (errores y descartes por dia)"
docker logs -t "$B" 2>&1 | grep -E "payload invalido|No se pudo persistir|descartado" | awk '{ print substr($1, 1, 10) }' | sort | uniq -c
docker logs -t "$B" 2>&1 | grep -c "Consumidor de 'chatbot_eventos_persistencia' arrancado" | sed 's/^/arranques del consumer en la ventana: /'

seccion "4. RabbitMQ: cola chatbot_eventos_persistencia (rabbitmqctl tarda ~6-7 s)"
docker exec "$R" rabbitmqctl -q list_queues name messages consumers 2>/dev/null < /dev/null | awk '$1 == "chatbot_eventos_persistencia" || NR == 1'

seccion "5. postgres-users: numero de usuarios (solo el conteo)"
# Los ids se pasan a postgres-vector por la tuberia y NUNCA se imprimen.
IDS=$(docker exec "$U" sh -c 'psql -X -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "BEGIN READ ONLY; SELECT coalesce(string_agg(id::text, '"','"'), '"''"') FROM mapcaloruser; COMMIT;"' < /dev/null | grep -vE '^(BEGIN|COMMIT)$' | tail -1)
echo "usuarios en mapcaloruser: $(echo "$IDS" | tr ',' '\n' | grep -c .)"

seccion "6. postgres-vector: indicadores (solo conteos, transaccion READ ONLY)"
docker exec -i "$V" sh -c 'psql -X -q -v ON_ERROR_STOP=1 -v ids="{'"$IDS"'}" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -A -F" | "' <<'SQL'
SET default_transaction_read_only = on;
SET statement_timeout = '30s';
BEGIN READ ONLY;
SHOW default_transaction_read_only;
SHOW transaction_read_only;

\echo '-- 6.1 totales'
SELECT (SELECT count(*) FROM conversaciones) AS conversaciones, (SELECT count(*) FROM mensajes) AS mensajes;

\echo '-- 6.2 conversaciones por dia de creacion (UTC)'
SELECT fecha::date AS dia, count(*) FROM conversaciones GROUP BY 1 ORDER BY 1;

\echo '-- 6.3 mensajes por dia y rol'
SELECT fecha::date AS dia, rol, count(*) FROM mensajes GROUP BY 1, 2 ORDER BY 1, 2;

\echo '-- 6.4 conversaciones sin usuario dueno valido (usuario_id no existe en postgres-users, o <= 0)'
SELECT count(*) FILTER (WHERE NOT (usuario_id = ANY (:'ids'::int[]))) AS usuario_inexistente,
       count(*) FILTER (WHERE usuario_id <= 0) AS usuario_cero_o_negativo
  FROM conversaciones;

\echo '-- 6.5 mensajes huerfanos (conversacion inexistente) y con rol fuera de usuario/asistente'
SELECT (SELECT count(*) FROM mensajes m WHERE NOT EXISTS (SELECT 1 FROM conversaciones c WHERE c.id = m.conversacion_id)) AS huerfanos,
       (SELECT count(*) FROM mensajes WHERE rol NOT IN ('usuario', 'asistente')) AS rol_invalido;

\echo '-- 6.6 huella del camino /chatbot/send -> consumer: par usuario->asistente con menos de 5 s'
\echo '--     entre ambos (el camino real del backend espera a Ollama: ~46 s por mensaje)'
WITH pares AS (
    SELECT m.conversacion_id, m.fecha AS f_usuario, m.intentos,
           lead(m.rol)   OVER w AS rol_sig,
           lead(m.fecha) OVER w AS f_sig
      FROM mensajes m
    WINDOW w AS (PARTITION BY m.conversacion_id ORDER BY m.fecha, m.id)
)
SELECT count(*) FILTER (WHERE rol_sig = 'asistente') AS pares_total,
       count(*) FILTER (WHERE rol_sig = 'asistente' AND f_sig - f_usuario < interval '5 seconds') AS pares_rapidos_lt5s,
       count(DISTINCT conversacion_id) FILTER (WHERE rol_sig = 'asistente' AND f_sig - f_usuario < interval '5 seconds') AS conversaciones_con_pares_rapidos,
       round(min(extract(epoch FROM f_sig - f_usuario)) FILTER (WHERE rol_sig = 'asistente')::numeric, 1) AS seg_min,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM f_sig - f_usuario)) FILTER (WHERE rol_sig = 'asistente'))::numeric, 1) AS seg_mediana,
       round(max(extract(epoch FROM f_sig - f_usuario)) FILTER (WHERE rol_sig = 'asistente')::numeric, 1) AS seg_max
  FROM pares;

\echo '-- 6.7 pares rapidos por dia, y si cayeron en una conversacion que YA existia (>60 s antes = posible inyeccion en ajena)'
WITH pares AS (
    SELECT m.conversacion_id, m.fecha AS f_usuario,
           lead(m.rol) OVER w AS rol_sig, lead(m.fecha) OVER w AS f_sig
      FROM mensajes m
    WINDOW w AS (PARTITION BY m.conversacion_id ORDER BY m.fecha, m.id)
)
SELECT p.f_usuario::date AS dia,
       count(*) AS pares_rapidos,
       count(*) FILTER (WHERE p.f_usuario - c.fecha > interval '60 seconds') AS en_conversacion_preexistente,
       count(*) FILTER (WHERE c.consentimiento_entrenamiento) AS con_consentimiento
  FROM pares p JOIN conversaciones c ON c.id = p.conversacion_id
 WHERE p.rol_sig = 'asistente' AND p.f_sig - p.f_usuario < interval '5 seconds'
 GROUP BY 1 ORDER BY 1;

\echo '-- 6.8 mensajes de usuario respondidos con intentos = 0 desde la migracion 0002 (indicador secundario:'
\echo '--     el camino con estados del backend deja intentos >= 1; el consumer y el camino legado dejan 0)'
SELECT count(*) FILTER (WHERE rol = 'usuario' AND estado = 'respondido' AND intentos = 0 AND fecha >= '2026-10-04') AS usuario_intentos_0,
       count(*) FILTER (WHERE rol = 'usuario' AND intentos >= 1) AS usuario_intentos_ge1
  FROM mensajes;

COMMIT;
SQL

seccion "FIN (solo lectura; nada se modifico)"
