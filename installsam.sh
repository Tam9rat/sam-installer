#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------
# PREVENT RUNNING WITH sudo
# ---------------------------------------------------------
if [[ "$USER" == "root" ]]; then
    echo "❌ ERROR: Do NOT run installer with sudo!"
    echo "   Run as normal user:"
    echo "   curl -sSL https://raw.githubusercontent.com/Tam9rat/sam-installer/main/installsam.sh | bash"
    exit 1
fi

echo ""
echo "===  SAM HUB INSTALLER  ==="
echo ""

# ---------------------------------------------------------
# AUTO-DETECT DEVICE ID
# ---------------------------------------------------------
DEVICE_ID="$(hostname)"
echo "Detected Device ID: $DEVICE_ID"
echo ""

RUN_USER="$USER"
USER_HOME="$HOME"

SSH_KEY_PATH="${USER_HOME}/.ssh/sam"
BOZO_PUB_PATH="${USER_HOME}/.ssh/bozocloud.pub"

REPO_SSH_URL="git@github.com:Tam9rat/sam.git"
REPO_DIR="${USER_HOME}/sam"
SERVICE_FILE="/etc/systemd/system/sam.service"

echo " User: $RUN_USER"
echo " Installing to: $REPO_DIR"
echo " SSH private key: $SSH_KEY_PATH"
echo " Cloud public key: $BOZO_PUB_PATH"
echo ""

mkdir -p "${USER_HOME}/.ssh"

# ---------------------------------------------------------
# DOWNLOAD DEPLOY KEY + CLOUD PUBLIC KEY
# ---------------------------------------------------------
echo "📥 Downloading deploy key from bozocloud…"
scp -o StrictHostKeyChecking=no root@www.bozocloud.it:/root/.ssh/sam "$SSH_KEY_PATH"

echo "📥 Downloading bozocloud.pub from server…"
mkdir -p "${USER_HOME}/.ssh/authorizedkeys"

scp -o StrictHostKeyChecking=no \
    root@www.bozocloud.it:/root/.ssh/bozocloud.pub \
    "${USER_HOME}/.ssh/authorizedkeys/bozocloud.pub"

chmod 700 "${USER_HOME}/.ssh/authorizedkeys"
chmod 644 "${USER_HOME}/.ssh/authorizedkeys/bozocloud.pub"


chmod 600 "$SSH_KEY_PATH"
chmod 644 "$BOZO_PUB_PATH"

# ---------------------------------------------------------
# SSH KNOWN HOSTS
# ---------------------------------------------------------
ssh-keyscan github.com >> "${USER_HOME}/.ssh/known_hosts" 2>/dev/null

# ---------------------------------------------------------
# REQUIREMENTS
# ---------------------------------------------------------
if ! command -v git >/dev/null; then
    echo "⬇ Installing git…"
    sudo apt update -y && sudo apt install -y git
fi

if ! command -v docker >/dev/null; then
    echo "⬇ Installing Docker…"
    curl -fsSL https://get.docker.com | sudo bash
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "⬇ Installing Docker Compose plugin…"
    sudo apt install -y docker-compose-plugin
fi

# ---------------------------------------------------------
# TEST SSH ACCESS
# ---------------------------------------------------------
echo ""
echo "🔐 Testing GitHub SSH authentication…"
SSH_TEST=$(ssh -i "$SSH_KEY_PATH" -T git@github.com 2>&1 || true)
echo "$SSH_TEST"

if ! echo "$SSH_TEST" | grep -q "successfully"; then
    echo "❌ SSH authentication FAILED — key is not authorized!"
    exit 1
fi
echo "✔ SSH OK"
echo ""

# ---------------------------------------------------------
# CLEAN DOCKER ENVIRONMENT
# ---------------------------------------------------------
clean_environment() {
    echo "Stopping old containers…"
    docker stop sam_set sam_mon corezo_gat corezo_pre 2>/dev/null || true

    echo "Removing old containers…"
    docker rm sam_set sam_mon corezo_gat corezo_pre 2>/dev/null || true

    echo "Removing images…"
    docker rmi sam_set sam_mon corezo_gat corezo_pre 2>/dev/null || true

    echo "Cleaning dangling images…"
    docker images -f "dangling=true" -q | xargs -r docker rmi || true
}

clean_environment

echo "🗑 Removing previous SAM folder…"
rm -rf "$REPO_DIR"

# ---------------------------------------------------------
# CLONE PRIVATE REPO
# ---------------------------------------------------------
echo "📦 Cloning SAM repository…"
GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH" git clone --depth 1 "$REPO_SSH_URL" "$REPO_DIR"

chmod +x "${REPO_DIR}/sam.sh"

# ---------------------------------------------------------
# DELETE KEY FOR SECURITY
# ---------------------------------------------------------
echo "🗑 Removing temporary private key…"
rm -f "$SSH_KEY_PATH"

# ---------------------------------------------------------
# BUILD DOCKER
# ---------------------------------------------------------
echo "🚀 Building Docker images…"
cd "$REPO_DIR"
docker compose build --no-cache
docker compose up -d --force-recreate

# ---------------------------------------------------------
# SYSTEMD SERVICE
# ---------------------------------------------------------
echo "🔧 Installing systemd service..."

sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=SAM Hub Service
After=docker.service network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/sam.sh up
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl enable sam.service
sudo systemctl restart sam.service

echo ""
echo "=== ✅ SAM INSTALLED AND RUNNING SUCCESSFULLY! ==="
echo "Logs: sudo journalctl -u sam.service -f"
echo ""
