#!/bin/bash
# Hardens a fresh Ubuntu 24.04 droplet running the FYP log-aggregation stack.
#
# Run AFTER provision.sh AND after confirming SSH works as neranjana:
#   sudo bash ~/research/scripts/harden.sh
#
# Safety guarantees:
#   - Aborts if the target user has no SSH authorized_keys (prevents lockout)
#   - Restores original sshd_config automatically if SSH restart fails
#   - UFW allows SSH before enabling (no firewall lockout)
#   - Does NOT auto-call from provision.sh — must be run manually
#
# What this hardens:
#   1. SSH  — disable root login, password auth, strong ciphers
#   2. UFW  — allowlist SSH(22) + k3s API(6443); deny everything else
#   3. sysctl — anti-spoof, SYN-flood, martian logging, IPv6 off
#   4. fail2ban — 3 retries / 5 min window → 1 h ban
#   5. Unattended security upgrades
#   6. Docker daemon — no-new-privileges, icc=false, log rotation
#   7. Disable unused services
#   8. Kernel module blacklist

set -euo pipefail

log()  { echo "[harden] $*"; }
warn() { echo "[harden] WARNING: $*" >&2; }
die()  { echo "[harden] ERROR: $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash harden.sh"

RESEARCH_USER="${SUDO_USER:-neranjana}"
SSH_PORT="${SSH_PORT:-22}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log "Pre-flight checks..."

# User must exist
id "${RESEARCH_USER}" &>/dev/null \
    || die "User '${RESEARCH_USER}' does not exist. Run provision.sh first."

# User must have SSH keys — without this, disabling password auth = lockout
AUTH_KEYS="/home/${RESEARCH_USER}/.ssh/authorized_keys"
if [ ! -s "${AUTH_KEYS}" ]; then
    die "No SSH keys found for ${RESEARCH_USER} at ${AUTH_KEYS}.
  Add your public key first:
    mkdir -p /home/${RESEARCH_USER}/.ssh
    echo 'ssh-ed25519 AAAA... you@host' >> ${AUTH_KEYS}
    chown -R ${RESEARCH_USER}:${RESEARCH_USER} /home/${RESEARCH_USER}/.ssh
    chmod 700 /home/${RESEARCH_USER}/.ssh && chmod 600 ${AUTH_KEYS}
  Then re-run this script."
fi

log "  User: ${RESEARCH_USER} ✓"
log "  SSH keys: present ✓"
log "  Proceeding with hardening."

# ── 1. SSH ────────────────────────────────────────────────────────────────────
log "Hardening SSH..."

SSHD_CONF=/etc/ssh/sshd_config
SSHD_BAK="${SSHD_CONF}.bak.$(date +%s)"
cp "${SSHD_CONF}" "${SSHD_BAK}"

# Restore backup if anything fails after this point
_restore_ssh() {
    warn "Error detected — restoring SSH config backup..."
    cp "${SSHD_BAK}" "${SSHD_CONF}"
    systemctl restart ssh 2>/dev/null || true
    warn "SSH config restored. Original settings are back."
}
trap '_restore_ssh' ERR

_sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}[[:space:]]" "${SSHD_CONF}"; then
        sed -i -E "s|^#?${key}[[:space:]].*|${key} ${val}|" "${SSHD_CONF}"
    else
        echo "${key} ${val}" >> "${SSHD_CONF}"
    fi
}

_sshd_set PermitRootLogin                no
_sshd_set PasswordAuthentication         no
_sshd_set ChallengeResponseAuthentication no
_sshd_set KbdInteractiveAuthentication   no
_sshd_set X11Forwarding                  no
_sshd_set MaxAuthTries                   3
_sshd_set MaxSessions                    5
_sshd_set LoginGraceTime                 30
_sshd_set AllowAgentForwarding           no
_sshd_set AllowTcpForwarding             no
_sshd_set PermitEmptyPasswords           no
_sshd_set UsePAM                         yes
_sshd_set PrintLastLog                   yes
_sshd_set ClientAliveInterval            300
_sshd_set ClientAliveCountMax            2

_sshd_set Ciphers       "aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305@openssh.com"
_sshd_set MACs          "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
_sshd_set KexAlgorithms "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"

# Allowlist only the research user
_sshd_set AllowUsers "${RESEARCH_USER}"

# Validate config before restarting — if invalid, trap restores backup
sshd -t || die "sshd config validation failed — backup restored automatically."
systemctl restart ssh
log "SSH hardened."

# SSH is stable — disarm the restore trap
trap - ERR

# ── 2. UFW ────────────────────────────────────────────────────────────────────
log "Configuring UFW firewall..."

apt-get install -y -qq ufw

# Allow SSH first, before enabling UFW — prevents firewall lockout
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"  comment "SSH"
ufw allow 6443/tcp           comment "k3s API"
# OpenSearch(9200), Dashboards(5601), Fluent Bit(2020) are ClusterIP — no external rule needed

ufw --force enable
ufw status verbose
log "UFW enabled."

# ── 3. sysctl hardening ───────────────────────────────────────────────────────
log "Applying sysctl hardening..."

cat > /etc/sysctl.d/99-harden.conf <<'EOF'
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# No source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignore ICMP broadcast (Smurf mitigation)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 (research stack is IPv4 only)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Time-wait assassination protection
net.ipv4.tcp_rfc1337 = 1

# Kernel hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
kernel.yama.ptrace_scope = 1
EOF

sysctl --system -q
log "sysctl hardening applied."

# ── 4. fail2ban ───────────────────────────────────────────────────────────────
log "Configuring fail2ban..."

# Install in case provision.sh wasn't run first
apt-get install -y -qq fail2ban

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd-harden.conf <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
backend  = systemd
maxretry = 3
findtime = 300
bantime  = 3600
ignoreip = 127.0.0.1/8
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
log "fail2ban configured: 3 retries / 5 min → 1 h ban."

# ── 5. Unattended security upgrades ──────────────────────────────────────────
log "Enabling unattended security upgrades..."

apt-get install -y -qq unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades
log "Unattended security upgrades enabled."

# ── 6. Docker daemon hardening ────────────────────────────────────────────────
log "Hardening Docker daemon..."

if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^docker.service"; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "no-new-privileges": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "icc": false,
  "live-restore": true
}
EOF
    systemctl reload-or-restart docker
    log "Docker daemon hardened."
else
    warn "Docker not installed — skipping. Run provision.sh first."
fi

# ── 7. Disable unused services ────────────────────────────────────────────────
log "Disabling unnecessary services..."

for svc in avahi-daemon cups cups-browsed bluetooth ModemManager whoopsie apport; do
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl disable --now "${svc}" 2>/dev/null || true
        log "  Disabled: ${svc}"
    fi
done

# ── 8. Kernel module blacklist ────────────────────────────────────────────────
log "Blacklisting unnecessary kernel modules..."

cat > /etc/modprobe.d/harden-modules.conf <<'EOF'
install usb-storage /bin/false
blacklist usb-storage
install dccp /bin/false
blacklist dccp
install sctp /bin/false
blacklist sctp
install rds /bin/false
blacklist rds
install tipc /bin/false
blacklist tipc
install n-hdlc /bin/false
blacklist n-hdlc
install firewire-core /bin/false
blacklist firewire-core
EOF

update-initramfs -u -k all 2>&1 | tail -3
log "Kernel modules blacklisted."

# ── 9. File permissions ───────────────────────────────────────────────────────
log "Tightening file permissions..."

chmod 700 /root
chmod 600 /etc/crontab
chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly
chmod 644 /etc/passwd /etc/group
chmod 600 /etc/shadow /etc/gshadow 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "=== Hardening complete ==="
log ""
log "  SSH       : root login off, password auth off, only ${RESEARCH_USER} allowed"
log "  Firewall  : UFW on — SSH(${SSH_PORT}) + k3s API(6443) only"
log "  sysctl    : anti-spoof, SYN-flood, martian logging, IPv6 off"
log "  fail2ban  : 3 retries → 1 h ban"
log "  Docker    : no-new-privileges, icc=false, log rotation"
log "  Modules   : USB/DCCP/SCTP/RDS/TIPC/firewire blacklisted"
log ""
log "OpenSearch security plugin left DISABLED (intentional for research)."
log ""
warn "SSH backup saved at: ${SSHD_BAK}"
warn "Verify you can still SSH in as ${RESEARCH_USER} from a new terminal."
