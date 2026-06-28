#!/bin/bash
# Provisions a fresh Ubuntu 24.04 DigitalOcean droplet to match the FYP
# log-aggregation research environment.
#
# Run as root (or with sudo) on the fresh droplet:
#   curl -fsSL https://raw.githubusercontent.com/NandiyaLive/fyp-log-aggregation/main/docs/provision.sh | bash
#   # or: bash provision.sh
#
# What this installs:
#   - Docker 29.x
#   - k3s v1.35.x (single node, traefik disabled)
#   - Helm v3.21.x
#   - fail2ban, jq, curl, python3
#   - OpenSearch 3.x + OpenSearch Dashboards via Helm (logging namespace)
#   - Fluent Bit DaemonSet (pipeline A by default)
#   - workload-generator Docker image (built from source)
#   - research git repo cloned to ~/research
#
# After provisioning, start the experiment with:
#   kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &
#   cd ~/research && ./scripts/run_all.sh clean_slate

set -euo pipefail

REPO_URL="https://github.com/NandiyaLive/fyp-log-aggregation"
RESEARCH_USER="${SUDO_USER:-neranjana}"
RESEARCH_HOME="/home/${RESEARCH_USER}"
K3S_VERSION="v1.35.4+k3s1"
HELM_VERSION="v3.21.0"

log() { echo "[provision] $*"; }

# ── 0. Prerequisites ──────────────────────────────────────────────────────────
log "Updating packages..."
apt-get update -qq
apt-get install -y -qq curl wget git jq python3 python3-pip fail2ban ca-certificates gnupg lsb-release

# ── 1. Docker ─────────────────────────────────────────────────────────────────
log "Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(lsb_release -cs)
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "${RESEARCH_USER}"
log "Docker installed."

# ── 2. k3s ────────────────────────────────────────────────────────────────────
log "Installing k3s ${K3S_VERSION}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
    --disable traefik \
    --write-kubeconfig-mode 644

# Wait for k3s to be ready
log "Waiting for k3s node to be Ready..."
until k3s kubectl get nodes | grep -q " Ready"; do sleep 3; done
log "k3s ready."

# Copy kubeconfig for the research user
mkdir -p "${RESEARCH_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${RESEARCH_HOME}/.kube/config"
chown -R "${RESEARCH_USER}:${RESEARCH_USER}" "${RESEARCH_HOME}/.kube"
chmod 600 "${RESEARCH_HOME}/.kube/config"

# Also available for root in this session
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── 3. Helm ───────────────────────────────────────────────────────────────────
log "Installing Helm ${HELM_VERSION}..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
    DESIRED_VERSION="${HELM_VERSION}" bash
log "Helm installed."

# ── 4. Clone research repo ────────────────────────────────────────────────────
log "Cloning research repo to ${RESEARCH_HOME}/research..."
if [ -d "${RESEARCH_HOME}/research" ]; then
    log "  (already exists, pulling latest)"
    cd "${RESEARCH_HOME}/research" && git pull
else
    git clone "${REPO_URL}" "${RESEARCH_HOME}/research"
fi
chown -R "${RESEARCH_USER}:${RESEARCH_USER}" "${RESEARCH_HOME}/research"
cd "${RESEARCH_HOME}/research"

# ── 5. Build workload-generator Docker image ──────────────────────────────────
log "Building workload-generator:latest..."
docker build -t workload-generator:latest workloads/
# Import into k3s containerd so k8s can use it without a registry
docker save workload-generator:latest | k3s ctr images import -
log "workload-generator image ready."

# ── 6. OpenSearch + Dashboards (Helm) ────────────────────────────────────────
log "Adding OpenSearch Helm repo..."
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm repo update

kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

log "Installing OpenSearch..."
helm upgrade --install opensearch opensearch/opensearch \
    -f configs/opensearch-values.yaml \
    -n logging \
    --wait --timeout 10m

log "Installing OpenSearch Dashboards..."
helm upgrade --install dashboards opensearch/opensearch-dashboards \
    -f configs/dashboards-values.yaml \
    -n logging \
    --wait --timeout 5m

# ── 7. Fluent Bit (pipeline A) ────────────────────────────────────────────────
log "Deploying Fluent Bit (pipeline A)..."
chmod +x scripts/deploy_fluentbit.sh
./scripts/deploy_fluentbit.sh A

# ── 8. Generate workloads ─────────────────────────────────────────────────────
if [ ! -f "workloads/workloads.json" ]; then
    log "Generating workloads.json..."
    sudo -u "${RESEARCH_USER}" python3 scripts/generate_workloads.py
fi

# ── 9. Fail2ban ───────────────────────────────────────────────────────────────
log "Enabling fail2ban..."
systemctl enable --now fail2ban

# ── 10. Harden ────────────────────────────────────────────────────────────────
log "Running hardening script..."
bash "${RESEARCH_HOME}/research/scripts/harden.sh"

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "=== Provisioning complete ==="
log ""
log "Droplet is ready. To start the experiment matrix:"
log "  ssh ${RESEARCH_USER}@<new-ip>"
log "  kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &"
log "  cd ~/research && ./scripts/run_all.sh clean_slate"
log ""
log "To restore previous results, copy docs/results-backup.tar.gz to the droplet and extract:"
log "  scp docs/results-backup.tar.gz ${RESEARCH_USER}@<new-ip>:~/"
log "  ssh ${RESEARCH_USER}@<new-ip> 'cd ~/research && tar xzf ~/results-backup.tar.gz'"
