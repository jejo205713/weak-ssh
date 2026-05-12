#!/usr/bin/env bash
#
# setup-weak-ssh.sh
# Configure OpenSSH on a lab VM with password authentication enabled.
# LAB / ISOLATED NETWORK USE ONLY. Do not run on production or internet-exposed hosts.
#

set -Eeuo pipefail

LOG_FILE="/var/log/setup-weak-ssh.log"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

# Default lab creds — override via env vars before invoking the script.
LAB_USER="${LAB_USER:-msfadmin}"
LAB_PASS="${LAB_PASS:-msfadmin}"
ROOT_PASS="${ROOT_PASS:-toor}"
ENABLE_ROOT_LOGIN="${ENABLE_ROOT_LOGIN:-yes}"
ENABLE_WEAK_CRYPTO="${ENABLE_WEAK_CRYPTO:-no}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=$1
    log "FAILED at line ${line_no} (exit ${exit_code})"
    if [[ -f "$BACKUP_FILE" ]]; then
        log "Restoring sshd_config from ${BACKUP_FILE}"
        cp -f "$BACKUP_FILE" "$SSHD_CONFIG" || log "Restore failed."
    fi
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Must run as root. Use sudo."
    fi
}

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

install_openssh() {
    local pm
    pm=$(detect_pkg_mgr)
    log "Detected package manager: ${pm}"

    case "$pm" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
            ;;
        dnf)
            dnf install -y openssh-server
            ;;
        yum)
            yum install -y openssh-server
            ;;
        pacman)
            pacman -Sy --noconfirm openssh
            ;;
        zypper)
            zypper --non-interactive install openssh
            ;;
        *)
            die "Unsupported package manager. Install openssh-server manually."
            ;;
    esac
}

detect_ssh_service() {
    if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
        echo "ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
        echo "sshd"
    else
        echo ""
    fi
}

backup_config() {
    [[ -f "$SSHD_CONFIG" ]] || die "sshd_config not found at ${SSHD_CONFIG}"
    cp -f "$SSHD_CONFIG" "$BACKUP_FILE"
    log "Backed up sshd_config -> ${BACKUP_FILE}"
}

set_sshd_option() {
    local key="$1"
    local value="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

harden_for_password_login() {
    set_sshd_option "PasswordAuthentication" "yes"
    set_sshd_option "PermitRootLogin" "${ENABLE_ROOT_LOGIN}"
    set_sshd_option "PermitEmptyPasswords" "no"
    set_sshd_option "PubkeyAuthentication" "no"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
    set_sshd_option "UsePAM" "yes"
    set_sshd_option "Port" "22"

    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        local override="${SSHD_CONFIG_DIR}/00-lab-password-login.conf"
        cat > "$override" <<EOF
# Lab override — password login.
PasswordAuthentication yes
PermitRootLogin ${ENABLE_ROOT_LOGIN}
PubkeyAuthentication no
KbdInteractiveAuthentication no
EOF
        log "Wrote drop-in override ${override}"
    fi
}

enable_weak_crypto() {
    [[ "$ENABLE_WEAK_CRYPTO" == "yes" ]] || return 0
    log "Enabling legacy crypto (lab only)."
    {
        echo ""
        echo "# Legacy crypto for old-tool practice — LAB ONLY"
        echo "KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"
        echo "HostKeyAlgorithms +ssh-rsa,ssh-dss"
        echo "PubkeyAcceptedAlgorithms +ssh-rsa,ssh-dss"
        echo "Ciphers +aes128-cbc,3des-cbc"
        echo "MACs +hmac-sha1"
    } >> "$SSHD_CONFIG"
}

ensure_user() {
    local user="$1"
    local pass="$2"
    if ! id "$user" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$user" || die "Failed to create user ${user}"
        log "Created user ${user}"
    else
        log "User ${user} already exists"
    fi
    echo "${user}:${pass}" | chpasswd || die "Failed to set password for ${user}"
    log "Password set for ${user}"
}

set_root_password() {
    [[ "$ENABLE_ROOT_LOGIN" == "yes" ]] || return 0
    echo "root:${ROOT_PASS}" | chpasswd || die "Failed to set root password"
    log "Root password set"
}

validate_config() {
    sshd -t 2>&1 | tee -a "$LOG_FILE" || die "sshd config validation failed (sshd -t)"
    log "sshd config validated"
}

start_service() {
    local svc
    svc=$(detect_ssh_service)
    [[ -n "$svc" ]] || die "Could not detect ssh service unit"

    systemctl enable "$svc" >/dev/null 2>&1 || log "Could not enable ${svc} (continuing)"
    systemctl restart "$svc" || die "Failed to restart ${svc}"
    sleep 1
    systemctl is-active --quiet "$svc" || die "${svc} not active after restart"
    log "${svc} active"
}

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 22/tcp || log "ufw rule add failed"
        log "ufw: allowed 22/tcp"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=ssh || log "firewalld add failed"
        firewall-cmd --reload || log "firewalld reload failed"
        log "firewalld: allowed ssh"
    fi
}

verify_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -E ':22[[:space:]]' || die "Nothing listening on :22"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -E ':22[[:space:]]' || die "Nothing listening on :22"
    else
        log "Neither ss nor netstat available; skipping listen check"
    fi
}

print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    ip="${ip:-<vm-ip>}"
    cat <<EOF

=========================================================
  OpenSSH password-login setup complete (LAB MODE).
---------------------------------------------------------
  Host        : ${ip}
  User        : ${LAB_USER}    Password: ${LAB_PASS}
  Root login  : ${ENABLE_ROOT_LOGIN}    Root pass: ${ROOT_PASS}
  Weak crypto : ${ENABLE_WEAK_CRYPTO}
  Backup      : ${BACKUP_FILE}
  Log         : ${LOG_FILE}

  Test from attacker box:
    ssh ${LAB_USER}@${ip}

  WARNING: lab / isolated network ONLY. Do not expose to internet.
=========================================================
EOF
}

main() {
    require_root
    touch "$LOG_FILE" || die "Cannot write log file ${LOG_FILE}"
    log "=== setup-weak-ssh.sh starting ==="

    install_openssh
    backup_config
    harden_for_password_login
    enable_weak_crypto
    ensure_user "$LAB_USER" "$LAB_PASS"
    set_root_password
    validate_config
    open_firewall
    start_service
    verify_listening
    print_summary

    log "=== setup-weak-ssh.sh done ==="
}

main "$@"
