#!/usr/bin/env bash
# ============================================================
# Techo 360 - Setup inicial del servidor
# ------------------------------------------------------------
# Se corre UNA SOLA VEZ, la primera vez que se prepara la VM.
# Requiere permisos de sudo para instalar Docker y crear el
# usuario de sistema, pero el resto del trabajo diario se hace
# con el usuario limitado que este script crea.
#
# Uso:
#   chmod +x setup-server.sh
#   ./setup-server.sh
# ============================================================

set -euo pipefail

DEPLOY_USER="techo360-deploy"
PROJECT_DIR="/opt/techo360"
GITHUB_USER="JuacoDev"

echo "=== 1. Actualizando el sistema ==="
sudo apt update && sudo apt upgrade -y

echo "=== 2. Instalando Docker ==="
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
else
  echo "Docker ya esta instalado, se omite."
fi

echo "=== 3. Verificando Docker Compose (plugin) ==="
docker compose version

echo "=== 4. Creando usuario de sistema limitado ($DEPLOY_USER) ==="
if ! id "$DEPLOY_USER" &> /dev/null; then
  sudo useradd -m -s /bin/bash "$DEPLOY_USER"
else
  echo "El usuario $DEPLOY_USER ya existe, se omite."
fi
sudo usermod -aG docker "$DEPLOY_USER"

echo "=== 5. Creando estructura de carpetas del proyecto ==="
sudo mkdir -p "$PROJECT_DIR"/{backups,logs}
sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$PROJECT_DIR"

echo "=== 6. Clonando los repositorios ==="
sudo -u "$DEPLOY_USER" bash -c "
  cd $PROJECT_DIR
  [ -d techo360-frontend ]   || git clone https://github.com/$GITHUB_USER/techo360-frontend.git
  [ -d techo360-backend ]    || git clone https://github.com/$GITHUB_USER/techo360-backend.git
  [ -d techo360-ai-service ] || git clone https://github.com/$GITHUB_USER/techo360-ai-service.git
  [ -d techo360-infra ]      || git clone https://github.com/$GITHUB_USER/techo360-infra.git
"

echo "=== 7. Recordatorio final ==="
echo "Setup completado."
echo "Antes de desplegar por primera vez:"
echo "  1. cd $PROJECT_DIR/techo360-infra"
echo "  2. cp .env.example .env  y completa las contrasenas reales"
echo "  3. Instala un runner self-hosted de GitHub Actions en CADA UNO de los 4 repos"
echo "     (Settings > Actions > Runners > New self-hosted runner, en cada repo)"
echo "  4. Primer arranque completo (crea todos los contenedores por primera vez):"
echo "       cd $PROJECT_DIR/techo360-infra && docker compose up -d --build"
echo "  5. Despliegues normales de un solo servicio:"
echo "       ./scripts/deploy-service.sh backend|ai-service|frontend"
echo "  6. Cambios de infraestructura (docker-compose.yml, etc.):"
echo "       ./scripts/deploy-infra.sh"
