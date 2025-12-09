#!/usr/bin/env bash
set -Eeuo pipefail

echo ""
echo "===  SAM HUB INSTALLER  ==="
echo ""

# ---------------------------------------------------------
# AUTO-DETECT DEVICE ID FROM HOSTNAME
# ---------------------------------------------------------
DEVICE_ID="$(hostname)"

if [[ -z "$DEVICE_ID" ]]; then
    echo " ERROR: hostname is empty. Cannot continue."
    exit 1
fi

echo "Detected Device ID from hostname: $DEVICE_ID"
echo ""

RUN_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~$RUN_USER)"
SSH_KEY_PATH="${USER_HOME}/.ssh/sam_${DEVICE_ID}"
REPO_SSH_URL="git@github.com:Tam9rat/sam.git"
REPO_DIR="${USER_HOME}/sam"
SERVICE_FILE="/etc/systemd/system/sam.service"

echo " User: $RUN_USER"
echo " Installing to: $REPO_DIR"
echo " SSH key: $SSH_KEY_PATH"
echo ""

# ---------------------------------------------------------
# GENERATE DEPLOY KEY IF NOT EXIST
# ---------------------------------------------------------
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "Generating SSH key: sam_${DEVICE_ID}"
    sudo -u "$RUN_USER" ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "sam_${DEVICE_ID}"

    echo ""
    echo "=== PUBLIC KEY — COPY THIS INTO GITHUB DEPLOY KEYS ==="
    echo ""
    cat "${SSH_KEY_PATH}.pub"
    echo ""
    echo "======================================================="
    echo ""
    read -rp "Add this key to GitHub → Repo → Settings → Deploy Keys. Press ENTER when done."
else
    echo "SSH key already exists: $SSH_KEY_PATH"
fi

sudo chmod 700 "${USER_HOME}/.ssh"
sudo chmod 600 "$SSH_KEY_PATH"
sudo -u "$RUN_USER" ssh-keyscan github.com >> "${USER_HOME}/.ssh/known_hosts" 2>/dev/null

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
echo "Testing GitHub SSH authentication…"
SSH_TEST=$(sudo -u "$RUN_USER" ssh -i "$SSH_KEY_PATH" -T git@github.com 2>&1 || true)
echo "$SSH_TEST"

if ! echo "$SSH_TEST" | grep -q "successfully"; then
    echo " SSH authentication FAILED — key probably not added to GitHub!"
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
sudo rm -rf "$REPO_DIR"

# ---------------------------------------------------------
# CLONE LATEST VERSION
# ---------------------------------------------------------
echo "Cloning latest SAM from GitHub…"
sudo -u "$RUN_USER" GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH" \
    git clone --depth 1 "$REPO_SSH_URL" "$REPO_DIR"

sudo chown -R "$RUN_USER:$RUN_USER" "$REPO_DIR"
sudo chmod +x "${REPO_DIR}/sam.sh"

# ---------------------------------------------------------
# BUILD DOCKER
# ---------------------------------------------------------
echo "Building Docker images…"
cd "$REPO_DIR"
docker compose up -d --build --no-cache --force-recreate

# ---------------------------------------------------------
# SYSTEMD SERVICE
# ---------------------------------------------------------
echo "Installing systemd service…"

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
echo "=== SAM INSTALLED AND RUNNING SUCCESSFULLY! ==="
echo "Logs: sudo journalctl -u sam.service -f"
echo ""
