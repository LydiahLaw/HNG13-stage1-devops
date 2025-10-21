#!/bin/bash
set -euo pipefail

LOGFILE="logs/deploy_$(date '+%Y%m%d_%H%M%S').log"
mkdir -p logs

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE"
}

error_exit() {
  log "ERROR: $1"
  exit "${2:-1}"
}

# 1. Collect Parameters
read -rp "Enter Git repository URL (HTTPS): " GIT_URL
read -rp "Enter Personal Access Token (PAT): " PAT
read -rp "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}
read -rp "Enter remote SSH username: " REMOTE_USER
read -rp "Enter remote server IP address: " REMOTE_IP
read -rp "Enter SSH key path (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -rp "Enter app internal container port (e.g. 3000): " APP_PORT

[[ -f "$SSH_KEY" ]] || error_exit "SSH key not found at $SSH_KEY"

# 2. Clone or update repo
REPO_NAME=$(basename -s .git "$GIT_URL")
if [ -d "$REPO_NAME" ]; then
  log "Repo exists, pulling latest..."
  git -C "$REPO_NAME" pull origin "$BRANCH" || error_exit "Git pull failed"
else
  log "Cloning repository..."
  git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" || error_exit "Git clone failed"
fi

cd "$REPO_NAME"

# 3. Verify Dockerfile exists
if [ ! -f "simple-node-app/Dockerfile" ]; then
  error_exit "No Dockerfile found in simple-node-app directory"
fi

# 4. SSH connectivity check
log "Checking SSH connectivity..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_IP" "echo ok" >/dev/null || error_exit "SSH failed"

# 5. Prepare remote server
log "Setting up remote environment..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash <<EOF
set -e
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx
sudo usermod -aG docker $USER || true
sudo systemctl enable --now docker
sudo systemctl enable --now nginx
sudo mkdir -p /opt/app
sudo chown -R $USER:$USER /opt/app
EOF

# 6. Deploy application
log "Syncing files..."
rsync -az --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" simple-node-app/ "$REMOTE_USER@$REMOTE_IP:/opt/app/" || error_exit "Rsync failed"

# 7. Run Docker container remotely
log "Building and starting container remotely..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash <<EOF
cd /opt/app
sudo docker stop simple-node-app || true
sudo docker rm simple-node-app || true
sudo docker build -t simple-node-app .
sudo docker run -d -p 3000:3000 --name simple-node-app simple-node-app
EOF

# 8. Configure Nginx
log "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash <<EOF
sudo tee /etc/nginx/sites-available/app.conf > /dev/null <<NGINXCONF
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://localhost:$APP_PORT;
  }
}
NGINXCONF
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo nginx -t && sudo systemctl reload nginx
EOF

# 9. Validate deployment
log "Checking application health..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "curl -s http://localhost:$APP_PORT || echo 'App not responding'" | tee -a "$LOGFILE"

log "Deployment completed successfully."
