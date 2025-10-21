#!/bin/sh
# deploy.sh
# POSIX style deploy script for stage 1 DevOps task
# Usage: ./deploy.sh       (interactive)
#        ./deploy.sh --cleanup   (removes deployed resources on remote)
set -eu

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGDIR="./logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/deploy_${TIMESTAMP}.log"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOGFILE"
}

error_exit() {
  log "ERROR: $1"
  exit "${2:-1}"
}

trap 'RC=$?; if [ "$RC" -ne 0 ]; then log "Script failed with exit code $RC"; fi' EXIT

# Simple arg parse for --cleanup
CLEANUP=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP=1
fi

log "Starting deploy script, cleanup=$CLEANUP"

# 1 Collect parameters
printf "Enter Git repository URL (full HTTPS URL, e.g. https://github.com/LydiahLaw/hng13-stage1-devops.git): "
read GIT_URL
if [ -z "$GIT_URL" ]; then error_exit "Git URL required"; fi
log "Got Git URL"

printf "Enter Personal Access Token (PAT). It will be used in clone command: "
stty -echo
read PAT
stty echo
printf "\n"
if [ -z "$PAT" ]; then error_exit "PAT required"; fi
log "PAT provided"

printf "Enter branch name (press Enter for 'main'): "
read BRANCH
BRANCH=${BRANCH:-main}
log "Branch set to $BRANCH"

printf "Enter remote SSH username: "
read REMOTE_USER
if [ -z "$REMOTE_USER" ]; then error_exit "Remote username required"; fi
log "Remote user: $REMOTE_USER"

printf "Enter remote server IP address: "
read REMOTE_IP
if [ -z "$REMOTE_IP" ]; then error_exit "Remote IP required"; fi
log "Remote IP: $REMOTE_IP"

printf "Enter SSH key path to use for remote (e.g. ~/.ssh/id_rsa): "
read SSH_KEY
if [ -z "$SSH_KEY" ]; then error_exit "SSH key path required"; fi
if [ ! -f "$SSH_KEY" ]; then error_exit "SSH key file not found at $SSH_KEY"; fi
log "SSH key exists"

printf "Enter application internal container port (e.g. 3000): "
read APP_PORT
if [ -z "$APP_PORT" ]; then error_exit "App port required"; fi
log "App port: $APP_PORT"

# Prepare clone URL with PAT (note: exposed in command history and process list)
CLONE_URL="$(printf '%s' "$GIT_URL" | sed "s#https://#https://${PAT}@#")"
REPO_NAME="$(basename "$GIT_URL" .git)"
log "Repo basename: $REPO_NAME"

# 2 Clone or pull repository locally
if [ -d "$REPO_NAME" ]; then
  log "Repository exists locally, pulling latest on branch $BRANCH"
  (cd "$REPO_NAME" && git fetch --all >>"$LOGFILE" 2>&1 || error_exit "git fetch failed" 2)
  (cd "$REPO_NAME" && git checkout "$BRANCH" >>"$LOGFILE" 2>&1 || error_exit "git checkout $BRANCH failed" 3)
  (cd "$REPO_NAME" && git pull origin "$BRANCH" >>"$LOGFILE" 2>&1 || error_exit "git pull failed" 4)
else
  log "Cloning repository"
  git clone --branch "$BRANCH" "$CLONE_URL" "$REPO_NAME" >>"$LOGFILE" 2>&1 || error_exit "git clone failed" 5
fi

# ensure inside directory
if [ ! -d "$REPO_NAME" ]; then error_exit "Repository directory missing after clone/pull"; fi
log "Repository ready at ./$REPO_NAME"

# verify dockerfile or docker-compose.yml presence
if [ -f "$REPO_NAME/Dockerfile" ] || [ -f "$REPO_NAME/docker-compose.yml" ]; then
  log "Found Dockerfile or docker-compose.yml"
else
  log "WARNING: no Dockerfile or docker-compose.yml found in repository"
fi

# If cleanup mode: run remote cleanup and local cleanup then exit
if [ "$CLEANUP" -eq 1 ]; then
  log "Running cleanup on remote"
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_IP" <<'REMOTE' >>"$LOGFILE" 2>&1 || true
set -eu
docker-compose -f /opt/app/docker-compose.yml down || true
docker rm -f app_container || true
docker rmi $(docker images -q my_app_image || true) || true
rm -rf /opt/app || true
rm -f /etc/nginx/sites-enabled/app.conf /etc/nginx/sites-available/app.conf || true
nginx -s reload || true
REMOTE
  log "Remote cleanup completed"
  exit 0
fi

# 3 Connectivity check to remote
log "Checking SSH connectivity to remote"
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_IP" "echo SSH_OK" >>"$LOGFILE" 2>&1 || error_exit "SSH connectivity failed" 6
log "SSH connectivity OK"

# 4 Prepare remote environment and deploy
log "Starting remote setup and deployment"

# Copy project to remote /opt/app using rsync
log "Syncing project files to remote /opt/app"
rsync -az --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" "$REPO_NAME"/ "$REMOTE_USER@$REMOTE_IP:/opt/app/" >>"$LOGFILE" 2>&1 || error_exit "rsync failed" 7

# Run remote commands: update, install docker, docker-compose, nginx, start services, run app
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_IP" /bin/sh <<REMOTE >>"$LOGFILE" 2>&1 || error_exit "Remote commands failed" 8
set -eu
log_remote() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

log_remote "Updating apt"
sudo apt-get update -y

# install dependencies for docker
log_remote "Installing prerequisites"
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# install docker if missing
if ! command -v docker >/dev/null 2>&1; then
  log_remote "Installing Docker engine"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

# install docker-compose plugin if missing
if ! command -v docker-compose >/dev/null 2>&1; then
  log_remote "Installing docker-compose"
  sudo curl -L "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose || true
fi

# install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  log_remote "Installing nginx"
  sudo apt-get install -y nginx
fi

# Add user to docker group if not already
if ! groups "$USER" | grep -q docker; then
  sudo usermod -aG docker "$USER" || true
fi

# Ensure services running
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

# confirm versions
docker --version || true
docker-compose --version || true
nginx -v || true

# Deploy application
REMOTE_APP_DIR="/opt/app"
cd "$REMOTE_APP_DIR" || exit 1

# If docker-compose.yml present, use it, otherwise build and run docker
if [ -f docker-compose.yml ]; then
  log_remote "Using docker-compose to deploy"
  sudo docker-compose down || true
  sudo docker-compose up -d --build
else
  # If Dockerfile exists try to build and run
  if [ -f Dockerfile ]; then
    log_remote "Building docker image my_app_image"
    sudo docker build -t my_app_image .
    # stop and remove any existing container named app_container
    sudo docker rm -f app_container || true
    log_remote "Running container app_container exposing internal port $APP_PORT"
    sudo docker run -d --name app_container -p 127.0.0.1:$APP_PORT:$APP_PORT my_app_image
  else
    log_remote "No Dockerfile or docker-compose.yml found, skipping app deploy"
  fi
fi

# Health check attempt: list containers
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Configure nginx reverse proxy
NGINX_CONF="/etc/nginx/sites-available/app.conf"
cat <<NGINX > /tmp/app.conf
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX
sudo mv /tmp/app.conf "$NGINX_CONF"
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/app.conf
sudo nginx -t
sudo systemctl reload nginx

log_remote "Remote deployment script finished"
REMOTE

log "Remote deploy finished, checking services"

# 5 Validate from local: test remote HTTP endpoint
log "Testing remote HTTP endpoint via curl"
if curl -sS --max-time 10 "http://$REMOTE_IP" >/dev/null 2>&1; then
  log "HTTP endpoint reachable at http://$REMOTE_IP"
else
  log "WARNING: HTTP endpoint not reachable at http://$REMOTE_IP"
fi

log "Deployment completed successfully"
exit 0
EOF
