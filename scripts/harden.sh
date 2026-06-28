#!/bin/bash
# Hardens a fresh Ubuntu 24.04 droplet running the FYP log-aggregation stack.
#
# Run as root AFTER provision.sh completes:
#   sudo bash scripts/harden.sh
#
# What this does:
#   1. SSH hardening (disable root login, password auth, set limits)
#   2. UFW firewall (allowlist: SSH + k3s API only; OpenSearch is ClusterIP)
#   3. sysctl network hardening (IP spoofing, SYN floods, ICMP redirects)
#   4. fail2ban tuned config for SSH
#   5. Unattended security upgrades
#   6. Docker daemon hardening (no-new-privileges, userland-proxy off)
#   7. Disable unused services
#   8. Kernel module lockdown (USB storage, uncommon network protocols)
#
# Does NOT touch OpenSearch security plugin — it is intentionally disabled
# (plugins.security.disabled: true) for the FYP research environment.

set -euo pipefail

log() { echo "[harden] $*"; }
warn() { echo "[harden] WARNING: $*" >&2; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

RESEARCH_USER="${SUDO_USER:-neranjana}"
SSH_PORT="${SSH_PORT:-22}"

# ── 1. SSH ────────────────────────────────────────────────────────────────────
log "Hardening SSH..."

SSHD_CONF=/etc/ssh/sshd_config
cp "${SSHD_CONF}" "${SSHD_CONF}.bak.$(date +%s)"

# Apply settings idempotently via sed + append-if-missing pattern
_sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}\s" "${SSHD_CONF}"; then
        sed -i -E "s|^#?${key}\s.*|${key} ${val}|" "${SSHD_CONF}"
    else
        echo "${key} ${val}" >> "${SSHD_CONF}"
    fi
}

_sshd_set PermitRootLogin               no
_sshd_set PasswordAuthentication        no
_sshd_set ChallengeResponseAuthentication no
_sshd_set KbdInteractiveAuthentication  no
_sshd_set X11Forwarding                 no
_sshd_set MaxAuthTries                  3
_sshd_set MaxSessions                   5
_sshd_set LoginGraceTime                30
_sshd_set AllowAgentForwarding          no
_sshd_set AllowTcpForwarding            no
_sshd_set PermitEmptyPasswords          no
_sshd_set UsePAM                        yes
_sshd_set PrintLastLog                  yes
_sshd_set ClientAliveInterval           300
_sshd_set ClientAliveCountMax           2

# Restrict to strong algorithms
_sshd_set Ciphers          "aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305@openssh.com"
_sshd_set MACs             "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
_sshd_set KexAlgorithms    "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"

# Allowlist only the research user
_sshd_set AllowUsers "${RESEARCH_USER}"

sshd -t && systemctl restart ssh
log "SSH hardened. Port: ${SSH_PORT}, root login: disabled, password auth: disabled."

# ── 2. UFW ────────────────────────────────────────────────────────────────────
log "Configuring UFW firewall..."

apt-get install -y -qq ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow "${SSH_PORT}/tcp" comment "SSH"

# k3s API server — needed if you kubectl from off-droplet.
# Comment out if you only ever kubectl from inside the droplet.
ufw allow 6443/tcp comment "k3s API"

# OpenSearch 9200 and Dashboards 5601 are ClusterIP — no external exposure needed.
# Fluent Bit 2020 metrics scrape is intra-cluster only.
# If you port-forward locally, no UFW rule required.

ufw --force enable
ufw status verbose
log "UFW enabled."

# ── 3. sysctl hardening ───────────────────────────────────────────────────────
log "Applying sysctl hardening..."

cat > /etc/sysctl.d/99-harden.conf <<'EOF'
# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects (prevents MITM via routing tricks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Don't accept source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignore ICMP broadcast (Smurf attack mitigation)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log martian packets (bogus source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 if unused (research stack is IPv4 only)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Protect against time-wait assassination
net.ipv4.tcp_rfc1337 = 1

# Kernel pointer leaks
kernel.kptr_restrict = 2

# Restrict dmesg to root
kernel.dmesg_restrict = 1

# Prevent core dumps from SUID binaries
fs.suid_dumpable = 0

# Restrict ptrace to direct children (mitigates some local priv-esc)
kernel.yama.ptrace_scope = 1
EOF

sysctl --system -q
log "sysctl hardening applied."

# ── 4. fail2ban ───────────────────────────────────────────────────────────────
log "Configuring fail2ban..."

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
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "";
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

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "no-new-privileges": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "icc": false,
  "live-restore": true
}
EOF

systemctl reload-or-restart docker
log "Docker daemon hardened."

# ── 7. Disable unused services ────────────────────────────────────────────────
log "Disabling unnecessary services..."

DISABLE_SERVICES=(
    avahi-daemon
    cups
    cups-browsed
    bluetooth
    ModemManager
    whoopsie
    apport
)

for svc in "${DISABLE_SERVICES[@]}"; do
    if systemctl list-unit-files --type=service | grep -q "^${svc}.service"; then
        systemctl disable --now "${svc}" 2>/dev/null || true
        log "  Disabled: ${svc}"
    fi
done

# ── 8. Kernel module lockdown ─────────────────────────────────────────────────
log "Blacklisting unnecessary kernel modules..."

cat > /etc/modprobe.d/harden-modules.conf <<'EOF'
# USB storage — no physical access needed on a droplet
install usb-storage /bin/false
blacklist usb-storage

# Uncommon / attack-surface network protocols
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

# Firewire (DMA attack surface)
install firewire-core /bin/false
blacklist firewire-core
EOF

update-initramfs -u -k all 2>&1 | tail -3
log "Kernel module blacklist written and initramfs updated."

# ── 9. System file permissions ────────────────────────────────────────────────
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
log "Summary:"
log "  SSH       : root login off, password auth off, allowlist=${RESEARCH_USER}"
log "  Firewall  : UFW enabled — SSH(${SSH_PORT}) + k3s API(6443) only"
log "  sysctl    : anti-spoof, SYN-flood, martian logging, IPv6 disabled"
log "  fail2ban  : 3 retries → 1h ban on SSH"
log "  Docker    : no-new-privileges, icc=false, log rotation"
log "  Modules   : USB storage, DCCP, SCTP, RDS, TIPC, firewire blacklisted"
log ""
log "OpenSearch security plugin remains DISABLED (research config)."
log "If you promote this to production, enable it and rotate certs."
log ""
warn "Verify SSH key auth still works before closing this session!"
