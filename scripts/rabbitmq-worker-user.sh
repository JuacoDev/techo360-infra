#!/usr/bin/env bash
# ============================================================
# Techo 360 - Usuario de RabbitMQ exclusivo para el pool de
# workers de chatbot (techo360-workers)
# ------------------------------------------------------------
# NO reusa RABBITMQ_USER/PASSWORD (el usuario compartido de
# backend/chatbot/proyeccion) -- crea uno nuevo, con el minimo
# permiso que necesita un worker:
#   - configure+read en chatbot_requests (declarar/consumir la cola)
#   - configure+write en chatbot_eventos_persistencia (publicar el
#     evento de persistencia, igual que ya hace el chatbot del VPS)
#   - write en 'amq.default' -- ese es el nombre real que RabbitMQ usa
#     para el chequeo de permisos del exchange por defecto (aunque en
#     AMQP se declare/publique con nombre vacio ""). Sin este permiso
#     el consumer recibe el mensaje, genera la respuesta con Ollama, y
#     luego el broker rechaza publicarla de vuelta por reply_to:
#     "ACCESS_REFUSED - write access to exchange 'amq.default' ...
#     refused for user 'techo360-worker'" -- confirmado real al validar
#     el primer worker (27-sep-2026).
#
# Idempotente: si el usuario ya existe, solo actualiza password y
# permisos (util para rotar la contrasena sin recrear el usuario).
#
# Se corre en el runner self-hosted del VPS (docker exec al
# contenedor de RabbitMQ), disparado por
# .github/workflows/manage-rabbitmq-worker-user.yml -- nunca via SSH
# manual, ver techo360/CLAUDE.md sobre el flujo de acceso al VPS.
#
# Uso: WORKER_RABBITMQ_PASSWORD=<pass> ./rabbitmq-worker-user.sh
# ============================================================
set -euo pipefail

WORKER_USER="techo360-worker"
CONTAINER="techo360-rabbitmq"

if [ -z "${WORKER_RABBITMQ_PASSWORD:-}" ]; then
  echo "Falta WORKER_RABBITMQ_PASSWORD en el entorno." >&2
  exit 1
fi

if docker exec "$CONTAINER" rabbitmqctl list_users --no-table-headers | awk '{print $1}' | grep -qx "$WORKER_USER"; then
  echo "--- Usuario '$WORKER_USER' ya existe: actualizando password ---"
  docker exec "$CONTAINER" rabbitmqctl change_password "$WORKER_USER" "$WORKER_RABBITMQ_PASSWORD"
else
  echo "--- Creando usuario '$WORKER_USER' ---"
  docker exec "$CONTAINER" rabbitmqctl add_user "$WORKER_USER" "$WORKER_RABBITMQ_PASSWORD"
fi

# Sin tag de administrador/management -- este usuario nunca debe poder
# entrar al panel de management ni ver otras colas/usuarios.
docker exec "$CONTAINER" rabbitmqctl set_user_tags "$WORKER_USER"

echo "--- Aplicando permisos minimos en vhost / ---"
docker exec "$CONTAINER" rabbitmqctl set_permissions -p / "$WORKER_USER" \
  "^(chatbot_requests|chatbot_eventos_persistencia)?$" \
  "^(chatbot_requests|chatbot_eventos_persistencia|amq\.default)$" \
  "^chatbot_requests$"

echo "--- Verificacion (permisos aplicados, sin exponer password) ---"
docker exec "$CONTAINER" rabbitmqctl list_user_permissions "$WORKER_USER"
docker exec "$CONTAINER" rabbitmqctl list_users
