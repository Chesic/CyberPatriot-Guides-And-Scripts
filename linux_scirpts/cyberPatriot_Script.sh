#!/bin/bash

### CyberPatriot Ubuntu Hardening Script ###

# This script covers the checklist items that are safe to automate
# benefit from an interactive prompt before changing anything.
# Items the user wants to handle by hand (unwanted services, auditd,
# rootkit scans, sysctl network hardening, cron/at restrictions) are NOT
# in this script - see manual_hardening_reference.md for those commands.

set -uo pipefail

### Setup ###

LOG_FILE="./cyberpatriot_hardening.log"

# Make sure the script is actually run as root, most steps below need it.
if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try: sudo ./cyberPatriot_Script.sh)"
    exit 1
fi

# log(): print a message and also append it (with a timestamp) to the log file.
log() {
    local message="$1"
    echo "${message}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" >> "${LOG_FILE}"
}

# confirm(): ask a yes/no question, defaults to "no" on empty input.
# returns 0 (true) for yes, 1 (false) for anything else.
confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

log "=== CyberPatriot hardening run started ==="

### 1. System Updates ###

system_updates() {
    echo ""
    echo "### System Updates ###"

    apt update

    # Show what's outdated before touching anything.
    apt list --upgradable

    if confirm "Run apt upgrade now?"; then
        apt upgrade -y
        log "Ran apt upgrade."
    else
        log "Skipped apt upgrade."
    fi

    if confirm "Install/enable unattended-upgrades (automatic security updates)?"; then
        apt install -y unattended-upgrades
        dpkg-reconfigure -plow unattended-upgrades
        log "Configured unattended-upgrades."
    fi
}

### 2. Firewall (ufw) ###

firewall_setup() {
    echo ""
    echo "### Firewall (ufw) ###"

    # Install ufw if it isn't already on the system.
    if ! command -v ufw >/dev/null 2>&1; then
        log "ufw not found, installing."
        apt install -y ufw
    fi

    ufw status verbose

    # Note: this script intentionally does NOT set default allow/deny
    # rules - that policy is left up to the user to configure by hand.
    if confirm "Enable ufw now?"; then
        ufw enable
        log "Enabled ufw."
    else
        log "Left ufw as-is (not enabled by script)."
    fi

    ufw status verbose
}

### 3. User / Account Audit ###

user_audit() {
    echo ""
    echo "### User / Account Audit ###"

    # Any account other than root with UID 0 is a big red flag.
    echo "Accounts with UID 0 (should only be root):"
    awk -F: '($3 == 0) {print $1}' /etc/passwd

    # Accounts with a blank password field in /etc/shadow can log in with no password.
    echo ""
    echo "Accounts with empty passwords:"
    local empty_pw_accounts
    empty_pw_accounts=$(awk -F: '($2 == "") {print $1}' /etc/shadow)
    echo "${empty_pw_accounts}"

    if [[ -n "${empty_pw_accounts}" ]]; then
        for user in ${empty_pw_accounts}; do
            if confirm "Lock account '${user}' (has empty password)?"; then
                passwd -l "${user}"
                log "Locked account: ${user} (empty password)."
            fi
        done
    fi
}

### 4. Password Policy ###

password_policy() {
    echo ""
    echo "### Password Policy ###"

    local login_defs="/etc/login.defs"
    local backup="${login_defs}.bak.$(date +%s)"

    cp "${login_defs}" "${backup}"
    log "Backed up ${login_defs} to ${backup}."

    # set_defs_value(): update a key if it exists, append it if it doesn't.
    set_defs_value() {
        local key="$1"
        local value="$2"
        if grep -qE "^${key}[[:space:]]" "${login_defs}"; then
            sed -i -E "s/^${key}[[:space:]]+.*/${key}\t${value}/" "${login_defs}"
        else
            echo -e "${key}\t${value}" >> "${login_defs}"
        fi
    }

    set_defs_value "PASS_MAX_DAYS" "90"
    set_defs_value "PASS_MIN_DAYS" "10"
    set_defs_value "PASS_WARN_AGE" "7"
    set_defs_value "FAILLOG_ENAB" "yes"
    set_defs_value "LOG_UNKFAIL_ENAB" "yes"
    set_defs_value "SYSLOG_SU_ENAB" "yes"
    set_defs_value "SYSLOG_SG_ENAB" "yes"

    log "Updated password policy values in ${login_defs}."
    grep -E "^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|FAILLOG_ENAB|LOG_UNKFAIL_ENAB|SYSLOG_SU_ENAB|SYSLOG_SG_ENAB)" "${login_defs}"
}

### 5. Sudoers Audit ###

sudoers_audit() {
    echo ""
    echo "### Sudoers Audit ###"

    # Read-only review - no automatic changes are made here.
    echo "--- /etc/sudoers ---"
    cat /etc/sudoers

    echo ""
    echo "--- /etc/sudoers.d/ ---"
    for f in /etc/sudoers.d/*; do
        [[ -f "${f}" ]] || continue
        echo "-- ${f} --"
        cat "${f}"
    done

    echo ""
    echo "Members of 'sudo' group:"
    getent group sudo

    echo "Members of 'admin' group (if it exists):"
    getent group admin

    log "Displayed sudoers configuration for manual review."
}

### 6. SSH Hardening ###

ssh_hardening() {
    echo ""
    echo "### SSH Hardening ###"

    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "${sshd_config}" ]]; then
        echo "sshd_config not found, skipping SSH hardening (OpenSSH server may not be installed)."
        return
    fi

    local backup="${sshd_config}.bak.$(date +%s)"
    cp "${sshd_config}" "${backup}"
    log "Backed up ${sshd_config} to ${backup}."

    set_sshd_value() {
        local key="$1"
        local value="$2"
        if grep -qE "^#?${key}[[:space:]]" "${sshd_config}"; then
            sed -i -E "s/^#?${key}[[:space:]]+.*/${key} ${value}/" "${sshd_config}"
        else
            echo "${key} ${value}" >> "${sshd_config}"
        fi
    }

    if confirm "Disable SSH root login (PermitRootLogin no)?"; then
        set_sshd_value "PermitRootLogin" "no"
        log "Set PermitRootLogin no."
    fi

    if confirm "Disable SSH empty passwords (PermitEmptyPasswords no)?"; then
        set_sshd_value "PermitEmptyPasswords" "no"
        log "Set PermitEmptyPasswords no."
    fi

    if confirm "Force SSH Protocol 2?"; then
        set_sshd_value "Protocol" "2"
        log "Set Protocol 2."
    fi

    if confirm "Restart sshd to apply changes?"; then
        systemctl restart sshd
        log "Restarted sshd."
    fi
}

### 7. Prohibited Files Scan ###

prohibited_files_scan() {
    echo ""
    echo "### Prohibited Files Scan ###"

    # Common places competitors keep media/hacking tools - adjust as needed.
    local search_dirs=("/home" "/root" "/tmp" "/media" "/mnt")

    echo "Searching for media files (music/video)..."
    local media_files
    media_files=$(find "${search_dirs[@]}" -type f \
        \( -iname "*.mp3" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mkv" \
           -o -iname "*.mov" -o -iname "*.wav" -o -iname "*.flac" \) \
        2>/dev/null)
    echo "${media_files}"

    echo ""
    echo "Searching for common hacking tool binaries..."
    local tools=("nmap" "wireshark" "netcat" "nc" "john" "hydra" "aircrack-ng")
    local found_tools=""
    for tool in "${tools[@]}"; do
        if command -v "${tool}" >/dev/null 2>&1; then
            found_tools+="${tool} "
        fi
    done
    echo "${found_tools}"

    if [[ -n "${media_files}" ]] && confirm "Delete the media files listed above?"; then
        while IFS= read -r file; do
            [[ -n "${file}" ]] || continue
            rm -f "${file}"
            log "Deleted prohibited file: ${file}"
        done <<< "${media_files}"
    fi

    if [[ -n "${found_tools}" ]]; then
        echo "Hacking tools found: ${found_tools}"
        echo "Review these manually - remove with 'apt remove <package>' if not authorized for the competition."
        log "Flagged installed tools for manual review: ${found_tools}"
    fi
}

### 8. File Permission Checks ###

file_permission_checks() {
    echo ""
    echo "### File Permission Checks ###"

    # Read-only report - flag anything unexpected for manual follow-up.
    echo "/etc/passwd permissions:"
    ls -l /etc/passwd

    echo "/etc/shadow permissions:"
    ls -l /etc/shadow

    echo ""
    echo "World-writable files under /etc (should normally be none):"
    find /etc -xdev -type f -perm -0002 2>/dev/null

    echo ""
    echo "SUID/SGID binaries on the system (review for anything unexpected):"
    find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null

    log "Completed file permission checks (read-only report)."
}

### 9. Summary ###

summary() {
    echo ""
    echo "### Summary ###"
    echo "Hardening run finished. Full log: ${LOG_FILE}"
    echo "See manual_hardening_reference.md for the checklist items handled by hand:"
    echo "  - Unwanted/insecure services"
    echo "  - auditd"
    echo "  - Malware/rootkit scan"
    echo "  - Network/kernel hardening (sysctl)"
    echo "  - Cron/at restrictions"
    log "=== CyberPatriot hardening run finished ==="
}

### Main ###

main() {
    system_updates
    firewall_setup
    user_audit
    password_policy
    sudoers_audit
    ssh_hardening
    prohibited_files_scan
    file_permission_checks
    summary
}

main
