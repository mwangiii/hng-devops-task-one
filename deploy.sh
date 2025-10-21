#!/usr/bin/env bash
# deploy.sh - Automated deployment for Dockerized app to remote Linux server
set -euo pipefail
IFS=$'\n\t'

########################
# Logging / housekeeping
########################
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="deploy_${TIMESTAMP}.log"
exec 3>&1 4>&2
# redirect stdout and stderr to log file and keep original fds
exec > >(tee -a "$LOGFILE") 2>&1

trap 'on_error $LINENO $?' ERR
trap cleanup_on_exit EXIT

on_error() {
    local lineno="$1"
    local code="${2:-1}"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR at line ${lineno}, exit code ${code}" >&2
    echo "See $LOGFILE for details." >&2
    # For non-zero exit, keep that code
    if [[ "$code" -ne 0 ]]; then
        exit "$code"
    fi
}

cleanup_on_exit() {
    # This runs on script exit (success or failure)
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script finished (exit code $?)"
}

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

####################
# Helper validations
####################
validate_non_empty() {
    local val="$1"; shift
    local msg="$*"
    if [[ -z "$val" ]]; then
        die "$msg"
    fi
}

validate_github_user_repo() {
    local repo="$1"
    # username/repo pattern (simple)
    if ! [[ "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        die "GitHub username/repo must be like 'username/repo' (no spaces)."
    fi
}

validate_port() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then
        die "Port must be a number."
    fi
    if (( p < 1 || p > 65535 )); then
        die "Port must be between 1 and 65535."
    fi
}

############################
# Interactive input collection
############################
CLEANUP_ONLY=false
if [[ "${1:-}" == "--cleanup" ]]; then
    CLEANUP_ONLY=true
fi

if [[ "$CLEANUP_ONLY" == false ]]; then
    # GitHub username/repo
    read -p "Enter GitHub username/repo (e.g., coolkeeds/myrepo): " github_user_repo
    validate_non_empty "$github_user_repo" "GitHub username/repo is required."
    validate_github_user_repo "$github_user_repo"
    github_url="https://github.com/${github_user_repo}.git"
    log "GitHub repo: $github_user_repo"

    # PAT (hidden)
    read -s -p "Enter GitHub Personal Access Token (input hidden): " github_pat
    echo
    validate_non_empty "$github_pat" "GitHub Personal Access Token is required."
    if (( ${#github_pat} < 8 )); then
        log "Warning: PAT length suspiciously short."
    fi

    # Branch (default main)
    read -p "Branch [main]: " branch
    branch=${branch:-main}

    # Remote SSH details
    read -p "Remote username: " remote_user
    validate_non_empty "$remote_user" "Remote username is required."
    read -p "Remote server IP/hostname: " remote_ip
    validate_non_empty "$remote_ip" "Remote server IP/hostname is required."
    read -p "SSH private key path (absolute or relative, e.g., ~/.ssh/id_rsa): " ssh_key
    validate_non_empty "$ssh_key" "SSH key path is required."
    if [[ ! -f "$ssh_key" ]]; then
        die "SSH key file not found at $ssh_key"
    fi

    # Application internal port (container)
    read -p "Application internal port (container port, e.g., 3000): " app_port
    validate_non_empty "$app_port" "Application port is required."
    validate_port "$app_port"

    # Local workdir
    repo_dir="${github_user_repo##*/}"   # repo name from username/repo
    local_workdir="$PWD/${repo_dir}"
    log "Local workdir is $local_workdir"
fi

####################
# SSH wrapper
####################
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$ssh_key")
ssh_exec() {
    # Usage: ssh_exec "command..."
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" "$@"
}

ssh_exec_here() {
    # Pass a heredoc (script) to remote bash -s
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" 'bash -s' <<'REMOTE'
set -euo pipefail
# The remote script body will be replaced dynamically below by local expansion
REMOTE
}

####################
# Clone or update repo locally
####################
clone_or_update_repo() {
    log "Cloning or updating repo locally..."
    # clone via PAT to support private repos
    # embed PAT into URL but do not echo it. Use credential temporarily.
    local safe_url="https://${github_user_repo}.git" # for logging only
    log "Repo (safe for display): $safe_url"

    if [[ -d "$local_workdir/.git" ]]; then
        log "Repository exists locally. Fetching and checking out branch $branch..."
        git -C "$local_workdir" fetch --all --prune
        git -C "$local_workdir" checkout "$branch" || git -C "$local_workdir" checkout -b "$branch" "origin/$branch" || true
        git -C "$local_workdir" pull --rebase origin "$branch" || true
    else
        log "Cloning repository (using PAT) into $local_workdir..."
        # Use token in URL temporarily; avoid printing it
        git clone --branch "$branch" "https://${github_pat}@github.com/${github_user_repo}.git" "$local_workdir"
    fi

    if [[ ! -d "$local_workdir" ]]; then
        die "Failed to clone or find repository at $local_workdir"
    fi

    # Check for Dockerfile or docker-compose.yml
    if [[ -f "$local_workdir/Dockerfile" ]]; then
        log "Found Dockerfile"
        compose_present=false
    elif [[ -f "$local_workdir/docker-compose.yml" || -f "$local_workdir/docker-compose.yaml" ]]; then
        log "Found docker-compose.yml"
        compose_present=true
    else
        die "Neither Dockerfile nor docker-compose.yml found in repository root."
    fi
}

####################
# Remote preparation
####################
prepare_remote() {
    log "Checking remote connectivity..."
    if ! ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" "echo 2>&1" >/dev/null; then
        die "SSH connection failed to ${remote_user}@${remote_ip}"
    fi
    log "SSH connectivity OK"

    log "Preparing remote environment (update, install docker, docker-compose, nginx if missing)..."
    # Use a heredoc to run idempotent installation commands remotely
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<'REMOTE_EOF'
set -euo pipefail
echo "Updating package lists..."
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    # Install dependencies idempotently
    sudo apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common
    # Docker install if missing
    if ! command -v docker >/dev/null 2>&1; then
        echo "Installing Docker..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        echo "Docker already installed: $(docker --version || true)"
    fi

    # Docker Compose (v2) - use apt if available, else use plugin
    if ! command -v docker-compose >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            echo "Docker Compose plugin available"
        else
            echo "Installing docker-compose plugin..."
            sudo apt-get install -y docker-compose-plugin || true
        fi
    fi

    # Nginx
    if ! command -v nginx >/dev/null 2>&1; then
        echo "Installing nginx..."
        sudo apt-get install -y nginx
    fi

    # Add user to docker group if not present
    if ! groups "$USER" | grep -qw docker; then
        echo "Adding $USER to docker group"
        sudo usermod -aG docker "$USER" || true
    fi

    # Start and enable services
    sudo systemctl enable --now docker || true
    sudo systemctl enable --now nginx || true

    echo "Remote preparation done"
else
    echo "This script supports apt-based systems. Please adapt for other distros." >&2
    exit 2
fi
REMOTE_EOF

    log "Remote environment prepared"
}

####################
# Transfer files
####################
transfer_project() {
    log "Transferring project files to remote host..."
    # Destination directory on remote
    remote_base_dir="~/deployments"
    remote_project_dir="${remote_base_dir}/${repo_dir}"

    # Create base dir on remote
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" "mkdir -p ${remote_base_dir}"

    # Use rsync to transfer (exclude .git)
    rsync -avz --delete --exclude '.git' -e "ssh ${SSH_OPTS[*]}" "$local_workdir/" "${remote_user}@${remote_ip}:${remote_project_dir}/"

    log "Files transferred to ${remote_project_dir}"
}

####################
# Remote deploy
####################
deploy_remote() {
    remote_project_dir="~/deployments/${repo_dir}"
    container_name="${repo_dir}_container"
    image_name="${repo_dir}_image:latest"
    nginx_site="/etc/nginx/sites-available/${repo_dir}"
    nginx_site_link="/etc/nginx/sites-enabled/${repo_dir}"

    # Build & run on remote depending on compose or Dockerfile
    if [[ "${compose_present:-false}" == true ]]; then
        log "Using docker-compose deployment on remote..."
        ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<REMOTE_EOF
set -euo pipefail
cd ${remote_project_dir}
# bring down old stack gracefully
if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
    echo "Stopping existing compose stack (if any)..."
    if [[ -f docker-compose.yml ]]; then
        docker compose down --remove-orphans || docker-compose down --remove-orphans || true
        # pull and build then up
        docker compose pull || true
        docker compose up -d --build
    else
        echo "docker-compose.yml not found in ${remote_project_dir}"
        exit 2
    fi
else
    echo "docker compose is not available on remote"
    exit 2
fi
REMOTE_EOF
    else
        log "Using Dockerfile build & container run on remote..."
        ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<REMOTE_EOF
set -euo pipefail
cd ${remote_project_dir}
# Stop and remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -w ${container_name} >/dev/null 2>&1; then
    echo "Stopping existing container ${container_name}..."
    docker stop ${container_name} || true
    docker rm ${container_name} || true
fi

# Build image
docker build -t ${image_name} .

# Run container (idempotent attempt)
# remove old container if exists then start new
docker run -d --name ${container_name} -p 127.0.0.1:${app_port}:${app_port} --restart unless-stopped ${image_name}
REMOTE_EOF
    fi

    log "Remote deployment commands executed"
    # Give containers a moment to start
    sleep 3
}

####################
# Configure Nginx on remote
####################
configure_nginx() {
    log "Configuring Nginx as reverse proxy to container port ${app_port}..."
    remote_project_dir="~/deployments/${repo_dir}"
    nginx_site="/etc/nginx/sites-available/${repo_dir}"
    nginx_site_link="/etc/nginx/sites-enabled/${repo_dir}"
    # Create nginx config dynamically and upload via ssh heredoc
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" sudo tee "${nginx_site}" > /dev/null <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://127.0.0.1:${app_port};
        proxy_read_timeout 90;
        proxy_redirect off;
    }
}
NGINXCONF

    # Ensure symlink exists
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<REMOTE_EOF
set -euo pipefail
if [[ ! -L "${nginx_site_link}" ]]; then
    sudo ln -sf "${nginx_site}" "${nginx_site_link}"
fi
sudo nginx -t
sudo systemctl reload nginx || sudo service nginx reload || true
REMOTE_EOF

    log "Nginx configured and reloaded"
}

####################
# Validation checks
####################
validate_deployment() {
    log "Validating deployment..."
    # Check docker service and container status
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<REMOTE_EOF
set -euo pipefail
# Docker running?
if ! systemctl is-active --quiet docker; then
    echo "Docker service not active" >&2
    exit 2
fi
# container check (either compose or single container)
if [[ -f ~/deployments/${repo_dir}/docker-compose.yml ]]; then
    # list compose services
    cd ~/deployments/${repo_dir}
    docker compose ps || docker-compose ps
else
    if ! docker ps --format '{{.Names}}' | grep -w ${repo_dir}_container >/dev/null 2>&1; then
        echo "Expected container ${repo_dir}_container not running" >&2
        exit 2
    fi
fi

# quick curl check to localhost:80 (nginx)
if ! curl -sS --connect-timeout 5 -I http://127.0.0.1/ >/dev/null 2>&1; then
    echo "Nginx reverse proxy didn't respond on remote" >&2
    exit 2
fi

echo "Remote validation OK"
REMOTE_EOF

    # Remote app endpoint test from local machine (optional)
    log "Testing endpoint from local (via curl to http://${remote_ip}/ )..."
    if ! curl -sS --connect-timeout 5 -I "http://${remote_ip}/" >/dev/null 2>&1; then
        log "Warning: Could not reach http://${remote_ip}/ from this host. The server may be behind firewall or cloud security group."
    else
        log "Public access test OK (http://${remote_ip}/ responded)."
    fi
}

####################
# Cleanup on remote
####################
cleanup_remote() {
    log "Running cleanup on remote (stop containers, remove project, remove nginx config)..."
    nginx_site="/etc/nginx/sites-available/${repo_dir}"
    nginx_site_link="/etc/nginx/sites-enabled/${repo_dir}"
    ssh "${SSH_OPTS[@]}" "${remote_user}@${remote_ip}" bash -s <<REMOTE_EOF
set -euo pipefail
# Stop compose or single container
if [[ -f ~/deployments/${repo_dir}/docker-compose.yml ]]; then
    cd ~/deployments/${repo_dir}
    docker compose down --remove-orphans || docker-compose down --remove-orphans || true
else
    if docker ps -a --format '{{.Names}}' | grep -w ${repo_dir}_container >/dev/null 2>&1; then
        docker stop ${repo_dir}_container || true
        docker rm ${repo_dir}_container || true
    fi
fi

# Remove project directory
rm -rf ~/deployments/${repo_dir}

# Remove nginx site and reload
if [[ -f "${nginx_site}" ]]; then
    sudo rm -f "${nginx_site}"
fi
if [[ -L "${nginx_site_link}" ]]; then
    sudo rm -f "${nginx_site_link}"
fi
sudo nginx -t || true
sudo systemctl reload nginx || true

echo "Cleanup done"
REMOTE_EOF

    log "Remote cleanup finished"
}

####################
# Main flow
####################
if [[ "$CLEANUP_ONLY" == true ]]; then
    # Require minimal inputs for cleanup
    read -p "Remote username: " remote_user
    read -p "Remote server IP/hostname: " remote_ip
    read -p "SSH private key path: " ssh_key
    validate_non_empty "$remote_user" "Remote username required"
    validate_non_empty "$remote_ip" "Remote IP required"
    validate_non_empty "$ssh_key" "SSH key required"
    read -p "Repo name (repo folder name, e.g., myrepo): " repo_dir
    validate_non_empty "$repo_dir" "Repo dir required"
    cleanup_remote
    exit 0
fi

log "Starting deployment (logfile: $LOGFILE)"
clone_or_update_repo
prepare_remote
transfer_project
deploy_remote
configure_nginx
validate_deployment

log "Deployment completed successfully."
exit 0