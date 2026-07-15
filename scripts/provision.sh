#!/bin/bash
# Provisions a fresh Ubuntu 24.04 DigitalOcean droplet for the FYP
# log-aggregation research environment.
#
# Run as root on the fresh droplet:
#   bash provision.sh
#
# What this installs:
#   - Creates neranjana user (copies root SSH keys so you can log in immediately)
#   - Docker 29.x
#   - k3s v1.35.x (single node, traefik disabled)
#   - Helm v3.21.x
#   - fail2ban, jq, curl, python3
#   - OpenSearch 3.x + OpenSearch Dashboards via Helm (logging namespace)
#   - Fluent Bit DaemonSet (pipeline A by default)
#   - workload-generator Docker image (built from source)
#   - research git repo cloned to ~/research
#
# After provisioning:
#   1. Open a NEW terminal and verify:  ssh neranjana@<ip>
#   2. If that works, run hardening:    sudo bash ~/research/scripts/harden.sh
#   3. Start experiment:
#        kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &
#        cd ~/research && ./scripts/run_all.sh clean_slate

set -euo pipefail

REPO_URL="https://github.com/NandiyaLive/fyp-log-aggregation"
RESEARCH_USER="neranjana"
RESEARCH_HOME="/home/${RESEARCH_USER}"
K3S_VERSION="v1.35.4+k3s1"
HELM_VERSION="v3.21.0"

log()  { echo "[provision] $*"; }
warn() { echo "[provision] WARNING: $*" >&2; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# ── 0. Prerequisites ──────────────────────────────────────────────────────────
log "Updating packages..."
apt-get update -qq
apt-get install -y -qq curl wget git jq python3 python3-pip \
    fail2ban ca-certificates gnupg lsb-release

# ── 1. Create research user ───────────────────────────────────────────────────
log "Setting up user: ${RESEARCH_USER}..."

if ! id "${RESEARCH_USER}" &>/dev/null; then
    adduser --disabled-password --gecos "" "${RESEARCH_USER}"
    log "  User created."
else
    log "  User already exists."
fi

usermod -aG sudo "${RESEARCH_USER}"

# Copy root's authorized SSH keys so the user can log in immediately
mkdir -p "${RESEARCH_HOME}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "${RESEARCH_HOME}/.ssh/authorized_keys"
    chown -R "${RESEARCH_USER}:${RESEARCH_USER}" "${RESEARCH_HOME}/.ssh"
    chmod 700 "${RESEARCH_HOME}/.ssh"
    chmod 600 "${RESEARCH_HOME}/.ssh/authorized_keys"
    log "  SSH keys copied from root → ${RESEARCH_USER}."
else
    warn "No SSH keys found in /root/.ssh/authorized_keys."
    warn "Add your public key to ${RESEARCH_HOME}/.ssh/authorized_keys before running harden.sh."
fi

# ── 2. Docker ─────────────────────────────────────────────────────────────────
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

# ── 3. k3s ────────────────────────────────────────────────────────────────────
log "Installing k3s ${K3S_VERSION}..."
# container-log-max-size/files: kubelet rotates and DELETES container logs at
# its default ~10Mi x 5 files. A 1M-line workload emits ~220MB, so the default
# deletes most of the log before Fluent Bit can tail it -> permanent, unintended
# loss that corrupts the baseline. Raise the cap so a whole workload log fits in
# one un-rotated file and survives until it is fully read.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
    --disable traefik \
    --write-kubeconfig-mode 644 \
    --kubelet-arg "container-log-max-size=1Gi" \
    --kubelet-arg "container-log-max-files=2"

log "Waiting for k3s node to be Ready..."
until k3s kubectl get nodes | grep -q " Ready"; do sleep 3; done
log "k3s ready."

mkdir -p "${RESEARCH_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${RESEARCH_HOME}/.kube/config"
chown -R "${RESEARCH_USER}:${RESEARCH_USER}" "${RESEARCH_HOME}/.kube"
chmod 600 "${RESEARCH_HOME}/.kube/config"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── 4. Helm ───────────────────────────────────────────────────────────────────
log "Installing Helm ${HELM_VERSION}..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
    DESIRED_VERSION="${HELM_VERSION}" bash
log "Helm installed."

# ── 5. Clone research repo ────────────────────────────────────────────────────
log "Cloning research repo to ${RESEARCH_HOME}/research..."
if [ -d "${RESEARCH_HOME}/research" ]; then
    log "  (already exists, pulling latest)"
    git -C "${RESEARCH_HOME}/research" pull
else
    git clone "${REPO_URL}" "${RESEARCH_HOME}/research"
fi
chown -R "${RESEARCH_USER}:${RESEARCH_USER}" "${RESEARCH_HOME}/research"

# ── 6. Build workload-generator Docker image ──────────────────────────────────
log "Building workload-generator:latest..."
docker build -t workload-generator:latest "${RESEARCH_HOME}/research/workloads/"
docker save workload-generator:latest | k3s ctr images import -
log "workload-generator image ready."

# ── 7. OpenSearch + Dashboards (Helm) ────────────────────────────────────────
log "Adding OpenSearch Helm repo..."
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm repo update

kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

log "Installing OpenSearch..."
helm upgrade --install opensearch opensearch/opensearch \
    -f "${RESEARCH_HOME}/research/configs/opensearch-values.yaml" \
    -n logging \
    --wait --timeout 10m

log "Installing OpenSearch Dashboards..."
helm upgrade --install dashboards opensearch/opensearch-dashboards \
    -f "${RESEARCH_HOME}/research/configs/dashboards-values.yaml" \
    -n logging \
    --wait --timeout 5m

# ── 8. Fluent Bit (pipeline A) ────────────────────────────────────────────────
log "Deploying Fluent Bit (pipeline A)..."
chmod +x "${RESEARCH_HOME}/research/scripts/deploy_fluentbit.sh"
"${RESEARCH_HOME}/research/scripts/deploy_fluentbit.sh" A

# ── 9. Generate workloads ─────────────────────────────────────────────────────
if [ ! -f "${RESEARCH_HOME}/research/workloads/workloads.json" ]; then
    log "Generating workloads.json..."
    sudo -u "${RESEARCH_USER}" python3 "${RESEARCH_HOME}/research/scripts/generate_workloads.py"
fi

# ── 10. Enable fail2ban ───────────────────────────────────────────────────────
log "Enabling fail2ban..."
systemctl enable --now fail2ban

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "=== Provisioning complete ==="
log ""
log "NEXT STEPS — do these in order:"
log ""
log "  1. Open a NEW terminal and verify SSH works as ${RESEARCH_USER}:"
log "       ssh ${RESEARCH_USER}@<droplet-ip>"
log ""
log "  2. If SSH works, run hardening (keeps root+password open until you confirm):"
log "       sudo bash ~/research/scripts/harden.sh"
log ""
log "  3. Start the experiment:"
log "       kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &"
log "       cd ~/research && ./scripts/run_all.sh clean_slate"
log ""
log "  To restore previous results:"
log "       scp docs/results-backup.tar.gz ${RESEARCH_USER}@<ip>:~/"
log "       ssh ${RESEARCH_USER}@<ip> 'cd ~/research && tar xzf ~/results-backup.tar.gz'"
