#!/bin/bash

### CyberPatriot Ubuntu Hardening Script ###

# Menu driven: nothing changes until you pick a section, and every change asks first.
# Read the README and answer the forensic questions BEFORE running anything.

set -uo pipefail

### Setup ###

LOG_FILE="./cyberpatriot_hardening.log"
ADMIN_GROUPS="sudo|admin|wheel"
MEDIA_EXTS=(mp3 mp4 wav flac avi mkv mov ogg m4a wma aac webm mpg mpeg)
SEARCH_DIRS=(/home /root /tmp /srv /opt /media /mnt /var/www)
WEAK_PASSWORDS=(password Password Password1 password1 password123 123456 12345678 123456789
    qwerty abc123 letmein admin changeme welcome iloveyou P@ssw0rd Passw0rd monkey dragon
    football 111111 000000 root toor)
PROHIBITED_PKGS="john|john-data|hydra|hydra-gtk|nmap|zenmap|wireshark|wireshark-qt|wireshark-common|tshark|netcat|netcat-traditional|netcat-openbsd|ncat|aircrack-ng|ophcrack|ophcrack-cli|ettercap-common|ettercap-graphical|kismet|nikto|sqlmap|medusa|fcrackzip|hashcat|nginx|nginx-core|samba|bind9|vsftpd|pure-ftpd|proftpd-basic|proftpd-core|tftpd|atftpd|tftpd-hpa|x11vnc|tightvncserver|tigervnc-standalone-server|vnc4server|snmp|snmpd|nfs-kernel-server|rpcbind|sendmail|sendmail-bin|postfix|xinetd|telnetd|telnet|inetutils-telnetd|rsh-server|rsh-client|nis|apache2|deluge|transmission-gtk|transmission-daemon|qbittorrent"
GAME_KEYWORDS="aisleriot|gnome-mines|gnome-sudoku|gnome-mahjongg|gnome-chess|gnome-robots|gnome-nibbles|gnome-tetravex|gnome-klotski|four-in-a-row|iagno|quadrapassel|hitori|lightsoff|swell-foop|tali|five-or-more|freeciv|supertux|minetest|wesnoth|steam|openttd|0ad|pingus|frozen-bubble|nethack|bsdgames|pacman|kpat|kmines|ksudoku|xboard|gnuchess|freecol|extremetuxracer|chromium-bsu|neverball|armagetron|openarena|warzone2100|lutris|playonlinux|minecraft|solitaire|tetris|doom"

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try: sudo ./cyberPatriot_Script.sh)"
    exit 1
fi

log() {
    echo "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

# Yes/no prompt, defaults to no.
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause() {
    read -r -p "Press Enter to continue..." _
}

header() {
    echo ""
    echo "=================================================="
    echo "### $1 ###"
    echo "=================================================="
}

pass() { echo "  [PASS] $1"; }
warn() { echo "  [WARN] $1"; }

backup_file() {
    local backup
    backup="$1.bak.$(date +%s)"
    cp -p "$1" "${backup}" && log "Backed up $1 to ${backup}."
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

human_users() {
    awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd
}

is_admin() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxE "${ADMIN_GROUPS}"
}

# Turns "1 3 5-7", "all" or "none" into a list of numbers between 1 and max.
parse_selection() {
    local input="$1" max="$2" token i
    [[ "${input}" =~ ^[Aa][Ll][Ll]$ ]] && { seq 1 "${max}"; return; }
    for token in ${input//,/ }; do
        if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i = BASH_REMATCH[1]; i <= BASH_REMATCH[2]; i++)); do
                ((i >= 1 && i <= max)) && echo "${i}"
            done
        elif [[ "${token}" =~ ^[0-9]+$ ]] && ((token >= 1 && token <= max)); then
            echo "${token}"
        fi
    done | sort -nu
}

# Sets "key value" style options (login.defs, sshd_config).
set_space_value() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^${key}[[:space:]]" "${file}"; then
        sed -i -E "s|^${key}[[:space:]].*|${key} ${value}|" "${file}"
    elif grep -qE "^#${key}[[:space:]]" "${file}"; then
        sed -i -E "0,/^#${key}[[:space:]].*/s||${key} ${value}|" "${file}"
    elif grep -qE "^Match[[:space:]]" "${file}"; then
        sed -i -E "0,/^Match[[:space:]]/s//${key} ${value}\n&/" "${file}"
    else
        echo "${key} ${value}" >> "${file}"
    fi
}

# Sets "key=value" options inside an ini style [section].
set_ini_value() {
    local file="$1" section="$2" key="$3" value="$4" section_re
    section_re=$(printf '%s' "${section}" | sed 's/[][*.^$/]/\\&/g')
    [[ -f "${file}" ]] || printf '[%s]\n' "${section}" > "${file}"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "${file}"
    elif grep -qE "^#${key}[[:space:]]*=" "${file}"; then
        sed -i -E "0,/^#${key}[[:space:]]*=.*/s||${key}=${value}|" "${file}"
    elif grep -qE "^\[${section_re}\]" "${file}"; then
        sed -i -E "/^\[${section_re}\]/a ${key}=${value}" "${file}"
    else
        printf '\n[%s]\n%s=%s\n' "${section}" "${key}" "${value}" >> "${file}"
    fi
}

### 1. System Updates ###

update_package() {
    local source="$1" pkg="$2"
    if [[ "${source}" == "snap" ]]; then
        snap refresh "${pkg}"
    else
        apt install --only-upgrade -y "${pkg}"
    fi
    log "Updated ${pkg} (${source})."
}

update_browsers() {
    local -a names=() sources=()
    local pkg i main
    for pkg in firefox firefox-esr chromium chromium-browser google-chrome-stable brave-browser microsoft-edge-stable opera-stable; do
        pkg_installed "${pkg}" && { names+=("${pkg}"); sources+=("apt"); }
    done
    if command -v snap >/dev/null 2>&1; then
        for pkg in firefox chromium brave opera; do
            snap list "${pkg}" >/dev/null 2>&1 && { names+=("${pkg}"); sources+=("snap"); }
        done
    fi

    if ((${#names[@]} == 0)); then
        echo "No common browsers detected."
        return
    fi

    echo "Browsers found:"
    for i in "${!names[@]}"; do
        printf "  %d) %s (%s)\n" $((i + 1)) "${names[i]}" "${sources[i]}"
    done
    read -r -p "Which number is the MAIN browser on this image? (0 = skip): " main

    if [[ "${main}" =~ ^[0-9]+$ ]] && ((main >= 1 && main <= ${#names[@]})); then
        i=$((main - 1))
        if confirm "Update main browser ${names[i]}?"; then
            update_package "${sources[i]}" "${names[i]}"
        fi
    fi
    for i in "${!names[@]}"; do
        [[ "$((i + 1))" == "${main}" ]] && continue
        if confirm "Also update ${names[i]} (${sources[i]})?"; then
            update_package "${sources[i]}" "${names[i]}"
        fi
    done
}

system_updates() {
    header "System Updates"
    apt update
    echo ""
    echo "Upgradable packages:"
    apt list --upgradable 2>/dev/null | tail -n +2

    if confirm "Run apt upgrade?"; then
        apt upgrade -y && log "Ran apt upgrade."
    fi
    if confirm "Run apt dist-upgrade (can add/remove packages)?"; then
        apt dist-upgrade -y && log "Ran apt dist-upgrade."
    fi
    if confirm "Upgrade systemd?"; then
        apt install --only-upgrade -y systemd && log "Upgraded systemd."
    fi

    echo ""
    update_browsers

    echo ""
    if confirm "Enable automatic daily security updates (unattended-upgrades)?"; then
        apt install -y unattended-upgrades
        local auto="/etc/apt/apt.conf.d/20auto-upgrades"
        [[ -f "${auto}" ]] && backup_file "${auto}"
        cat > "${auto}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        log "Enabled automatic updates in ${auto}."
    fi
}

verify_updates() {
    local count
    count=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c .)
    ((count == 0)) && pass "No pending upgrades" || warn "${count} packages still upgradable"
    grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades \
        && pass "Automatic updates enabled" || warn "Automatic updates not enabled"
}

### 2. User Management ###

print_user_table() {
    local user uid shell admin
    printf "  %-18s %-7s %-20s %s\n" "USER" "UID" "SHELL" "ADMIN"
    for user in root $(human_users); do
        uid=$(id -u "${user}")
        shell=$(getent passwd "${user}" | cut -d: -f7)
        admin="no"
        { is_admin "${user}" || [[ "${user}" == "root" ]]; } && admin="YES"
        printf "  %-18s %-7s %-20s %s\n" "${user}" "${uid}" "${shell}" "${admin}"
    done
}

make_admin() {
    local group
    for group in sudo adm; do
        getent group "${group}" >/dev/null && usermod -aG "${group}" "$1"
    done
    log "Made $1 an administrator (sudo, adm)."
}

make_standard() {
    local group
    for group in sudo adm admin wheel; do
        id -nG "$1" | tr ' ' '\n' | grep -qx "${group}" && gpasswd -d "$1" "${group}" >/dev/null
    done
    log "Removed admin rights from $1."
}

user_management() {
    header "User Management"
    local -a users
    local user choice names name
    local me="${SUDO_USER:-root}"
    mapfile -t users < <(human_users)

    print_user_table
    echo ""
    echo "For each user choose: [k]eep as is, [a]dmin, [s]tandard user, [d]elete (Enter = keep)"
    for user in "${users[@]}"; do
        read -r -p "  ${user}$(is_admin "${user}" && echo ' (admin)'): " choice
        case "${choice,,}" in
            a) make_admin "${user}" ;;
            s) make_standard "${user}" ;;
            d)
                if [[ "${user}" == "${me}" ]]; then
                    echo "  Refusing to delete ${user}, you are logged in as this user."
                elif confirm "  Really delete ${user} and their home directory?"; then
                    userdel -r "${user}" 2>/dev/null || userdel "${user}"
                    log "Deleted user ${user}."
                fi
                ;;
            *) ;;
        esac
    done

    echo ""
    if confirm "Create any missing users from the README?"; then
        read -r -p "Usernames to create (space separated): " names
        for name in ${names}; do
            if id "${name}" >/dev/null 2>&1; then
                echo "  ${name} already exists."
                continue
            fi
            useradd -m -s /bin/bash "${name}" && log "Created user ${name}."
            echo "  Set a password for ${name}:"
            passwd "${name}"
            confirm "  Make ${name} an admin?" && make_admin "${name}"
        done
    fi

    echo ""
    echo "Accounts with UID 0 other than root:"
    awk -F: '$3 == 0 && $1 != "root" {print "  " $1}' /etc/passwd
    echo "Duplicate UIDs:"
    cut -d: -f3 /etc/passwd | sort | uniq -d | sed 's/^/  /'
    echo "Duplicate GIDs:"
    cut -d: -f3 /etc/group | sort | uniq -d | sed 's/^/  /'

    echo ""
    echo "System accounts (UID < 1000) with a login shell:"
    local -a sys_accounts
    mapfile -t sys_accounts < <(awk -F: '$3 > 0 && $3 < 1000 && $7 ~ /(ba|z|da)?sh$/ {print $1}' /etc/passwd)
    for user in "${sys_accounts[@]}"; do
        if confirm "  Set ${user}'s shell to /usr/sbin/nologin?"; then
            usermod -s /usr/sbin/nologin "${user}" && log "Set ${user} shell to nologin."
        fi
    done

    echo ""
    passwd -S root
    if confirm "Lock the root account (passwd -l root)?"; then
        passwd -l root && log "Locked root account."
    fi

    echo ""
    print_user_table
}

verify_users() {
    local others
    others=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | xargs)
    [[ -z "${others}" ]] && pass "Only root has UID 0" || warn "Other UID 0 accounts: ${others}"
    [[ -z "$(cut -d: -f3 /etc/passwd | sort | uniq -d)" ]] && pass "No duplicate UIDs" || warn "Duplicate UIDs found"
    passwd -S root | awk '{print $2}' | grep -q '^L' && pass "root account locked" || warn "root account not locked"
    echo "  Admins: $(for u in $(human_users); do is_admin "$u" && printf '%s ' "$u"; done)"
}

### 3. Password Audit ###

# Prints why a user's password is insecure, or nothing if it looks OK.
password_issue() {
    local user="$1" entry hash lastchg max_days age pw
    local -a reasons=()
    entry=$(getent shadow "${user}") || return
    hash=$(cut -d: -f2 <<< "${entry}")
    lastchg=$(cut -d: -f3 <<< "${entry}")

    case "${hash}" in
        "") echo "empty password"; return ;;
        '!'* | '*'*) return ;;
    esac
    [[ "${hash}" == '$1$'* ]] && reasons+=("weak MD5 hash")
    [[ "${hash}" != '$'* ]] && reasons+=("weak DES hash")

    for pw in "${WEAK_PASSWORDS[@]}" "${user}" "${user}1" "${user}123" "${user}!"; do
        if perl -e 'exit(crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? 0 : 1)' -- "${pw}" "${hash}"; then
            reasons+=("common/guessable password")
            break
        fi
    done

    max_days=$(awk '/^PASS_MAX_DAYS/ {print $2}' /etc/login.defs)
    if [[ "${lastchg}" =~ ^[0-9]+$ && "${max_days:-}" =~ ^[0-9]+$ ]] && ((lastchg > 0)); then
        age=$(($(date +%s) / 86400 - lastchg))
        ((age > max_days)) && reasons+=("not changed in ${age} days")
    fi
    (IFS=","; echo "${reasons[*]}")
}

meets_policy() {
    local pw="$1"
    [[ ${#pw} -ge 10 && "${pw}" =~ [A-Z] && "${pw}" =~ [a-z] && "${pw}" =~ [0-9] && "${pw}" =~ [^A-Za-z0-9] ]]
}

password_audit() {
    header "Password Audit"
    echo "Checks for empty, weak-hash, common/guessable and expired passwords."
    echo "Passwords that pass these checks are left alone."
    echo ""
    local -a flagged=()
    local user issue status new_pw
    for user in root $(human_users); do
        issue=$(password_issue "${user}")
        status=$(passwd -S "${user}" 2>/dev/null | awk '{print $2}')
        if [[ -n "${issue}" ]]; then
            printf "  %-18s INSECURE: %s\n" "${user}" "${issue}"
            flagged+=("${user}")
        elif [[ "${status}" == L* ]]; then
            printf "  %-18s locked\n" "${user}"
        else
            printf "  %-18s OK\n" "${user}"
        fi
    done

    if ((${#flagged[@]} == 0)); then
        echo ""
        echo "No insecure passwords found."
        return
    fi

    echo ""
    while true; do
        read -r -s -p "New password for flagged users (Enter = Cyb3rPatr!0t\$): " new_pw
        echo ""
        new_pw="${new_pw:-Cyb3rPatr!0t\$}"
        meets_policy "${new_pw}" && break
        echo "Password must be 10+ chars with upper, lower, number and symbol."
    done

    for user in "${flagged[@]}"; do
        if confirm "Change password for ${user}?"; then
            echo "${user}:${new_pw}" | chpasswd && log "Changed password for ${user}."
        fi
    done
}

verify_passwords() {
    local user issue bad=0
    for user in root $(human_users); do
        issue=$(password_issue "${user}")
        [[ -n "${issue}" ]] && { warn "${user}: ${issue}"; bad=1; }
    done
    ((bad == 0)) && pass "No insecure passwords detected"
}

### 4. Password Policy ###

password_policy() {
    header "Password Policy"
    local login_defs="/etc/login.defs"
    local common_pw="/etc/pam.d/common-password"
    local common_auth="/etc/pam.d/common-auth"
    local key opt

    echo "Will set: PASS_MAX_DAYS 90, PASS_MIN_DAYS 10, PASS_WARN_AGE 7, FAILLOG/LOG_UNKFAIL/SYSLOG_SU/SYSLOG_SG yes"
    if confirm "Apply these to ${login_defs}?"; then
        backup_file "${login_defs}"
        set_space_value "${login_defs}" "PASS_MAX_DAYS" "90"
        set_space_value "${login_defs}" "PASS_MIN_DAYS" "10"
        set_space_value "${login_defs}" "PASS_WARN_AGE" "7"
        for key in FAILLOG_ENAB LOG_UNKFAIL_ENAB SYSLOG_SU_ENAB SYSLOG_SG_ENAB; do
            set_space_value "${login_defs}" "${key}" "yes"
        done
        log "Updated ${login_defs}."
        if confirm "Also apply max/min/warn ages to existing users?"; then
            for key in $(human_users); do
                chage -M 90 -m 10 -W 7 "${key}"
            done
            log "Applied password ages to existing users."
        fi
    fi

    echo ""
    if confirm "Enforce complexity in PAM (minlen=10, upper/lower/digit/symbol)?"; then
        pkg_installed libpam-pwquality || apt install -y libpam-pwquality
        if ! pkg_installed libpam-pwquality; then
            echo "libpam-pwquality could not be installed, PAM left unchanged."
            return
        fi
        backup_file "${common_pw}"
        if ! grep -q "pam_pwquality.so" "${common_pw}"; then
            sed -i '0,/^password.*pam_unix\.so/s//password\trequisite\t\t\tpam_pwquality.so retry=3\n&/' "${common_pw}"
        fi
        for opt in minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 difok=3; do
            key="${opt%%=*}"
            if grep -qE "pam_pwquality\.so.*\b${key}=" "${common_pw}"; then
                sed -i -E "/pam_pwquality\.so/ s/\b${key}=[^[:space:]]*/${opt}/" "${common_pw}"
            else
                sed -i -E "/pam_pwquality\.so/ s/$/ ${opt}/" "${common_pw}"
            fi
        done
        log "Updated pam_pwquality settings in ${common_pw}."
        grep "pam_pwquality.so" "${common_pw}"
    fi

    if grep -q "nullok" "${common_auth}" && confirm "Remove 'nullok' (blank password logins) from ${common_auth}?"; then
        backup_file "${common_auth}"
        sed -i -E 's/[[:space:]]+nullok(_secure)?//g' "${common_auth}"
        log "Removed nullok from ${common_auth}."
    fi
}

verify_policy() {
    local key value
    for key in PASS_MAX_DAYS:90 PASS_MIN_DAYS:10 PASS_WARN_AGE:7; do
        value=$(awk -v k="${key%%:*}" '$1 == k {print $2}' /etc/login.defs)
        [[ "${value}" == "${key##*:}" ]] && pass "${key%%:*} = ${value}" || warn "${key%%:*} = ${value:-unset}"
    done
    grep -qE "pam_pwquality\.so.*minlen=" /etc/pam.d/common-password \
        && pass "pam_pwquality complexity set" || warn "pam_pwquality complexity not set"
    grep -q "nullok" /etc/pam.d/common-auth && warn "nullok still in common-auth" || pass "nullok removed"
}

### 5. Firewall ###

configure_ufw() {
    ufw status verbose
    if systemctl is-active --quiet ssh 2>/dev/null && confirm "SSH is running. Allow SSH through the firewall?"; then
        ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp
        log "Allowed SSH through ufw."
    fi
    if confirm "Set default policy (deny incoming, allow outgoing)?"; then
        ufw default deny incoming && ufw default allow outgoing
        log "Set ufw default policies."
    fi
    if confirm "Enable ufw now?"; then
        ufw --force enable && log "Enabled ufw."
    fi
    ufw status verbose
}

firewall_setup() {
    header "Firewall"
    if command -v ufw >/dev/null 2>&1; then
        configure_ufw
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "This system uses firewalld."
        firewall-cmd --state
        if confirm "Enable and start firewalld?"; then
            systemctl enable --now firewalld && log "Enabled firewalld."
        fi
    else
        echo "No ufw or firewalld found. Current iptables rules:"
        iptables -L -n 2>/dev/null | head -20
        if confirm "Install ufw? (check the README first)"; then
            apt install -y ufw && configure_ufw
        fi
    fi
}

verify_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -q "Status: active" && pass "ufw active" || warn "ufw not active"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state >/dev/null 2>&1 && pass "firewalld running" || warn "firewalld not running"
    else
        warn "No firewall installed"
    fi
}

### 6. Login Screen ###

login_screen() {
    header "Login Screen (LightDM / GDM)"
    local found=0 file

    if pkg_installed lightdm; then
        found=1
        echo "LightDM detected. Will set: allow-guest=false, greeter-hide-users=true,"
        echo "greeter-show-manual-login=true, autologin-user=none"
        if confirm "Apply LightDM settings?"; then
            for file in /etc/lightdm/lightdm.conf /usr/share/lightdm/lightdm.conf.d/50-ubuntu.conf; do
                [[ "${file}" == /usr/* && ! -f "${file}" ]] && continue
                mkdir -p "$(dirname "${file}")"
                [[ -f "${file}" ]] && backup_file "${file}"
                set_ini_value "${file}" "Seat:*" "allow-guest" "false"
                set_ini_value "${file}" "Seat:*" "greeter-hide-users" "true"
                set_ini_value "${file}" "Seat:*" "greeter-show-manual-login" "true"
                set_ini_value "${file}" "Seat:*" "autologin-user" "none"
                log "Updated ${file}."
            done
        fi
    fi

    if pkg_installed gdm3; then
        found=1
        echo "GDM detected. Will set: disable-user-list=true, disable-restart-buttons=true,"
        echo "AutomaticLoginEnable=false, TimedLoginEnable=false"
        if confirm "Apply GDM settings?"; then
            file="/etc/gdm3/greeter.dconf-defaults"
            [[ -f "${file}" ]] && backup_file "${file}"
            set_ini_value "${file}" "org/gnome/login-screen" "disable-user-list" "true"
            set_ini_value "${file}" "org/gnome/login-screen" "disable-restart-buttons" "true"
            file="/etc/gdm3/custom.conf"
            [[ -f "${file}" ]] && backup_file "${file}"
            set_ini_value "${file}" "daemon" "AutomaticLoginEnable" "false"
            set_ini_value "${file}" "daemon" "TimedLoginEnable" "false"
            command -v dconf >/dev/null 2>&1 && dconf update
            log "Updated GDM settings."
        fi
    fi

    ((found == 0)) && echo "Neither LightDM nor GDM is installed."
    echo "Changes apply after a reboot (the display manager is not restarted)."
}

verify_login() {
    if pkg_installed lightdm; then
        grep -qs "^allow-guest=false" /etc/lightdm/lightdm.conf && pass "LightDM guest disabled" || warn "LightDM guest not disabled"
        grep -qs "^autologin-user=none" /etc/lightdm/lightdm.conf && pass "LightDM autologin off" || warn "LightDM autologin not set"
    fi
    if pkg_installed gdm3; then
        grep -qs "^AutomaticLoginEnable=false" /etc/gdm3/custom.conf && pass "GDM autologin off" || warn "GDM autologin not disabled"
        grep -qs "^disable-user-list=true" /etc/gdm3/greeter.dconf-defaults && pass "GDM user list hidden" || warn "GDM user list shown"
    fi
}

### 7. SSH Hardening ###

ssh_hardening() {
    header "SSH Hardening"
    local sshd_config="/etc/ssh/sshd_config"
    local setting

    if ! pkg_installed openssh-server; then
        echo "openssh-server is not installed, nothing to do."
        return
    fi

    if ! confirm "Is SSH a required service in the README?"; then
        if confirm "Stop and remove openssh-server?"; then
            systemctl disable --now ssh 2>/dev/null
            apt purge -y openssh-server && log "Removed openssh-server."
        fi
        return
    fi

    backup_file "${sshd_config}"
    for setting in "PermitRootLogin no" "PermitEmptyPasswords no" "LoginGraceTime 60" \
        "X11Forwarding no" "UsePAM yes" "PasswordAuthentication yes" "Protocol 2"; do
        if confirm "Set '${setting}'?"; then
            set_space_value "${sshd_config}" "${setting%% *}" "${setting#* }"
            log "Set ${setting} in ${sshd_config}."
        fi
    done

    if ls /etc/ssh/sshd_config.d/*.conf >/dev/null 2>&1; then
        echo ""
        echo "Note: files in /etc/ssh/sshd_config.d/ override sshd_config:"
        grep -H -v '^\s*#' /etc/ssh/sshd_config.d/*.conf | grep .
    fi

    if ! sshd -t; then
        echo "sshd config test failed, restoring backup."
        cp -p "$(ls -t "${sshd_config}".bak.* | head -1)" "${sshd_config}"
        log "Restored ${sshd_config} after failed config test."
        return
    fi
    if confirm "Restart SSH to apply changes?"; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        log "Restarted SSH."
    fi
}

verify_ssh() {
    pkg_installed openssh-server || { pass "openssh-server not installed"; return; }
    local effective
    effective=$(sshd -T 2>/dev/null)
    grep -qi "^permitrootlogin no" <<< "${effective}" && pass "PermitRootLogin no" || warn "Root login allowed over SSH"
    grep -qi "^permitemptypasswords no" <<< "${effective}" && pass "PermitEmptyPasswords no" || warn "Empty passwords allowed over SSH"
    grep -qi "^x11forwarding no" <<< "${effective}" && pass "X11Forwarding no" || warn "X11Forwarding enabled"
}

### 8. Sudoers Audit ###

sudoers_audit() {
    header "Sudoers Audit"
    local file
    local -a files=(/etc/sudoers)
    for file in /etc/sudoers.d/*; do
        [[ -f "${file}" && "$(basename "${file}")" != *[.~]* ]] && files+=("${file}")
    done

    for file in "${files[@]}"; do
        echo "--- ${file} (active lines) ---"
        grep -vE '^\s*(#|$)' "${file}" | grep -v '^#include'
    done

    echo ""
    echo "Members of admin groups:"
    getent group sudo admin wheel

    for file in "${files[@]}"; do
        if grep -nE '^[^#]*(NOPASSWD|!authenticate)' "${file}"; then
            if confirm "Remove NOPASSWD / !authenticate from ${file}?"; then
                backup_file "${file}"
                sed -i -E '/^[[:space:]]*#/! s/NOPASSWD:[[:space:]]*//g' "${file}"
                sed -i -E '/^[[:space:]]*Defaults.*!authenticate/d' "${file}"
                if visudo -c -f "${file}" >/dev/null; then
                    log "Removed NOPASSWD / !authenticate from ${file}."
                else
                    cp -p "$(ls -t "${file}".bak.* | head -1)" "${file}"
                    echo "visudo check failed, restored ${file}."
                fi
            fi
        fi
    done
}

verify_sudoers() {
    if find /etc/sudoers /etc/sudoers.d -maxdepth 1 -type f ! -name '*.*' ! -name '*~' \
        -exec grep -qsE '^[^#]*(NOPASSWD|!authenticate)' {} +; then
        warn "NOPASSWD or !authenticate still present"
    else
        pass "No NOPASSWD / !authenticate in sudoers"
    fi
    visudo -c >/dev/null 2>&1 && pass "sudoers syntax OK" || warn "sudoers syntax error"
}

### 9. Prohibited Software ###

find_prohibited_packages() {
    dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
        | awk '$NF == "installed" {print $1}' | grep -xE "${PROHIBITED_PKGS}"
}

prohibited_software() {
    header "Prohibited Software"
    echo "Some images REQUIRE tools like wireshark, nmap or samba. Check the README first."
    local -a pkgs selected=()
    local i choice
    mapfile -t pkgs < <(find_prohibited_packages)
    if ((${#pkgs[@]} == 0)); then
        echo "No packages from the prohibited list are installed."
        return
    fi

    for i in "${!pkgs[@]}"; do
        printf "  %2d) %-26s %s\n" $((i + 1)) "${pkgs[i]}" \
            "$(dpkg-query -W -f='${binary:Summary}' "${pkgs[i]}" 2>/dev/null)"
    done
    read -r -p "Numbers to REMOVE (e.g. 1 3 5-7, all, Enter = none): " choice
    for i in $(parse_selection "${choice}" "${#pkgs[@]}"); do
        selected+=("${pkgs[i - 1]}")
    done
    ((${#selected[@]} == 0)) && return

    echo "Selected: ${selected[*]}"
    echo "apt will show everything that gets removed and ask before continuing."
    apt purge "${selected[@]}" && log "Purged packages: ${selected[*]}"
    if confirm "Run apt autoremove to clean up leftover dependencies?"; then
        apt autoremove -y
    fi
}

verify_software() {
    local remaining
    remaining=$(find_prohibited_packages | xargs)
    [[ -z "${remaining}" ]] && pass "No listed prohibited packages installed" \
        || warn "Still installed (OK if README requires): ${remaining}"
}

### 10. Prohibited Media Files ###

find_media() {
    local -a expr=() dirs=()
    local ext dir
    for ext in "${MEDIA_EXTS[@]}"; do
        expr+=(-o -iname "*.${ext}")
    done
    for dir in "${SEARCH_DIRS[@]}"; do
        [[ -d "${dir}" ]] && dirs+=("${dir}")
    done
    find "${dirs[@]}" -type f \( "${expr[@]:1}" \) -print0 2>/dev/null
}

prohibited_media() {
    header "Prohibited Media Files"
    if ! confirm "Does the README say media files (mp3, mp4, etc.) are prohibited / scan for them?"; then
        return
    fi
    echo "Default types: ${MEDIA_EXTS[*]}"
    if confirm "Also include images (jpg, jpeg, png, gif)?"; then
        MEDIA_EXTS+=(jpg jpeg png gif)
    fi
    local extra i choice
    read -r -p "Any other extensions to search for (space separated, Enter = none): " extra
    for i in ${extra}; do
        MEDIA_EXTS+=("${i#.}")
    done

    local -a files selected=()
    mapfile -d '' files < <(find_media)
    if ((${#files[@]} == 0)); then
        echo "No matching media files found."
        return
    fi

    for i in "${!files[@]}"; do
        printf "  %3d) %-8s %-12s %s\n" $((i + 1)) "$(du -h "${files[i]}" | cut -f1)" \
            "$(stat -c %U "${files[i]}")" "${files[i]}"
    done
    read -r -p "Numbers to DELETE (e.g. 1 3 5-7, all, Enter = none): " choice
    for i in $(parse_selection "${choice}" "${#files[@]}"); do
        selected+=("${files[i - 1]}")
    done
    ((${#selected[@]} == 0)) && return

    if confirm "Delete ${#selected[@]} file(s)?"; then
        for i in "${selected[@]}"; do
            rm -f -- "${i}" && log "Deleted media file: ${i}"
        done
    fi
}

verify_media() {
    local count
    count=$(find_media | tr -cd '\0' | wc -c)
    ((count == 0)) && pass "No media files found" || warn "${count} media files remain (OK if allowed)"
}

### 11. Game Software ###

# Prints "type<TAB>name" for every likely game found.
find_games() {
    local file pkg
    {
        dpkg-query -W -f='${Section}\t${Package}\t${Status}\n' 2>/dev/null \
            | awk -F'\t' '$3 ~ / installed$/ && $1 ~ /games$/ {print "apt\t" $2}'
        dpkg-query -W -f='${Package}\t${Status}\n' 2>/dev/null \
            | awk -F'\t' '$2 ~ / installed$/ {print $1}' | grep -iE "^(${GAME_KEYWORDS})" | sed 's/^/apt\t/'
        if command -v snap >/dev/null 2>&1; then
            snap list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -iE "^(${GAME_KEYWORDS})" | sed 's/^/snap\t/'
        fi
        if command -v flatpak >/dev/null 2>&1; then
            flatpak list --app --columns=application 2>/dev/null | grep -iE "${GAME_KEYWORDS}|game" | sed 's/^/flatpak\t/'
        fi
        for file in /usr/games/* /usr/local/games/* \
            $(grep -lsE '^Categories=.*Game' /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop \
                /home/*/.local/share/applications/*.desktop /home/*/Desktop/*.desktop); do
            [[ -e "${file}" ]] || continue
            pkg=$(dpkg -S "${file}" 2>/dev/null | head -1 | cut -d: -f1)
            if [[ -n "${pkg}" ]]; then
                echo -e "apt\t${pkg}"
            else
                echo -e "file\t${file}"
            fi
        done
    } | sort -u
}

game_software() {
    header "Game Software Detection"
    local -a games apt_pkgs=()
    local i choice type name
    mapfile -t games < <(find_games)
    if ((${#games[@]} == 0)); then
        echo "No likely games found."
        return
    fi

    for i in "${!games[@]}"; do
        printf "  %2d) %-8s %s\n" $((i + 1)) "${games[i]%%$'\t'*}" "${games[i]#*$'\t'}"
    done
    read -r -p "Numbers to REMOVE (e.g. 1 3 5-7, all, Enter = none): " choice

    for i in $(parse_selection "${choice}" "${#games[@]}"); do
        type="${games[i - 1]%%$'\t'*}"
        name="${games[i - 1]#*$'\t'}"
        case "${type}" in
            apt) apt_pkgs+=("${name}") ;;
            snap) confirm "Remove snap ${name}?" && snap remove "${name}" && log "Removed snap ${name}." ;;
            flatpak) confirm "Remove flatpak ${name}?" && flatpak uninstall -y "${name}" && log "Removed flatpak ${name}." ;;
            file) confirm "Delete ${name}?" && rm -rf -- "${name}" && log "Deleted game file ${name}." ;;
        esac
    done

    if ((${#apt_pkgs[@]} > 0)); then
        echo "apt will show everything that gets removed and ask before continuing."
        apt purge "${apt_pkgs[@]}" && log "Purged game packages: ${apt_pkgs[*]}"
    fi
}

verify_games() {
    local count
    count=$(find_games | grep -c .)
    ((count == 0)) && pass "No likely games found" || warn "${count} possible games remain"
}

### 12. Services Review ###

services_review() {
    header "Services Review (report only)"
    echo "Listening ports:"
    ss -tulnp
    echo ""
    echo "Running services:"
    systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print "  " $1}'
    echo ""
    echo "Running services that are often prohibited (check the README):"
    systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}' \
        | grep -iE 'apache|nginx|smbd|nmbd|vsftpd|ftp|telnet|snmp|nfs|rpcbind|bind9|named|postfix|sendmail|xinetd|vnc|cups|avahi' \
        | sed 's/^/  /'
    echo ""
    echo "Nothing is changed here. To stop a service by hand: systemctl disable --now <service>"
    echo "To remove the software behind it use option 9 (Prohibited Software)."
}

### 13. Kernel / Network (sysctl) ###

SYSCTL_FILE="/etc/sysctl.d/99-cyberpatriot.conf"
SYSCTL_SETTINGS=(
    "net.ipv4.conf.all.accept_redirects = 0"
    "net.ipv4.conf.default.accept_redirects = 0"
    "net.ipv4.conf.all.secure_redirects = 0"
    "net.ipv4.ip_forward = 0"
    "net.ipv4.conf.all.send_redirects = 0"
    "net.ipv4.conf.default.send_redirects = 0"
    "net.ipv4.conf.all.rp_filter = 1"
    "net.ipv4.conf.default.rp_filter = 1"
    "net.ipv4.conf.all.accept_source_route = 0"
    "net.ipv4.conf.all.log_martians = 1"
    "net.ipv4.icmp_echo_ignore_broadcasts = 1"
    "net.ipv4.tcp_max_syn_backlog = 2048"
    "net.ipv4.tcp_synack_retries = 2"
    "net.ipv4.tcp_syn_retries = 5"
    "net.ipv4.tcp_syncookies = 1"
    "kernel.randomize_va_space = 2"
)

kernel_hardening() {
    header "Kernel / Network Hardening (sysctl)"
    printf '  %s\n' "${SYSCTL_SETTINGS[@]}"
    if ! confirm "Write these settings to ${SYSCTL_FILE}?"; then
        return
    fi
    [[ -f "${SYSCTL_FILE}" ]] && backup_file "${SYSCTL_FILE}"
    printf '%s\n' "${SYSCTL_SETTINGS[@]}" > "${SYSCTL_FILE}"

    if confirm "Disable IPv6 too? (only if the README doesn't need it)"; then
        printf '%s\n' "net.ipv6.conf.all.disable_ipv6 = 1" "net.ipv6.conf.default.disable_ipv6 = 1" \
            "net.ipv6.conf.lo.disable_ipv6 = 1" >> "${SYSCTL_FILE}"
    fi
    sysctl --system >/dev/null && log "Applied sysctl settings from ${SYSCTL_FILE}."
}

verify_kernel() {
    local setting key want have
    for setting in "${SYSCTL_SETTINGS[@]}"; do
        key="${setting%% =*}"
        want="${setting##*= }"
        have=$(sysctl -n "${key}" 2>/dev/null)
        [[ "${have}" == "${want}" ]] && pass "${key} = ${have}" || warn "${key} = ${have:-unknown} (want ${want})"
    done
}

### 14. Cron Jobs Review ###

cron_review() {
    header "Cron Jobs Review"
    local file user
    echo "--- /etc/crontab ---"
    grep -vE '^\s*(#|$)' /etc/crontab 2>/dev/null
    for file in /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
        [[ -f "${file}" ]] && echo "  ${file}"
    done

    echo ""
    echo "--- User crontabs ---"
    for file in /var/spool/cron/crontabs/*; do
        [[ -f "${file}" ]] || continue
        user=$(basename "${file}")
        echo "-- ${user} --"
        grep -vE '^\s*(#|$)' "${file}"
        if confirm "Remove the crontab for ${user}?"; then
            cp -p "${file}" "${LOG_FILE%/*}/crontab_${user}.bak"
            crontab -r -u "${user}" && log "Removed crontab for ${user} (backup saved next to the log)."
        fi
    done

    echo ""
    echo "--- /etc/rc.local ---"
    grep -vE '^\s*(#|$)' /etc/rc.local 2>/dev/null || echo "  (none)"
    echo "--- /etc/init.d ---"
    ls /etc/init.d
    echo ""
    echo "Edit or delete suspicious system cron files by hand after checking them."
}

verify_cron() {
    local users
    users=$(find /var/spool/cron/crontabs -mindepth 1 -maxdepth 1 -printf "%f " 2>/dev/null)
    [[ -z "${users}" ]] && pass "No user crontabs" || warn "User crontabs exist for: ${users}"
}

### 15. File Permissions ###

PERM_TARGETS=("/etc/passwd:644:root:root" "/etc/group:644:root:root"
    "/etc/shadow:640:root:shadow" "/etc/gshadow:640:root:shadow" "/etc/sudoers:440:root:root")

file_permissions() {
    header "File Permissions"
    local entry file mode owner group
    for entry in "${PERM_TARGETS[@]}"; do
        IFS=: read -r file mode owner group <<< "${entry}"
        [[ -f "${file}" ]] || continue
        echo "  $(stat -c '%a %U:%G %n' "${file}")   (want ${mode} ${owner}:${group})"
        if [[ "$(stat -c '%a %U:%G' "${file}")" != "${mode} ${owner}:${group}" ]] \
            && confirm "  Fix ${file}?"; then
            chmod "${mode}" "${file}" && chown "${owner}:${group}" "${file}"
            log "Set ${file} to ${mode} ${owner}:${group}."
        fi
    done

    echo ""
    echo "World-writable files under /etc (should be none):"
    find /etc -xdev -type f -perm -0002 2>/dev/null
    echo ""
    echo "SUID/SGID binaries outside the usual system folders (review these):"
    find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null \
        | grep -vE '^/(usr/)?(s?bin|lib|libexec)/|^/snap/'
}

verify_permissions() {
    local entry file mode owner group
    for entry in "${PERM_TARGETS[@]}"; do
        IFS=: read -r file mode owner group <<< "${entry}"
        [[ -f "${file}" ]] || continue
        [[ "$(stat -c '%a %U:%G' "${file}")" == "${mode} ${owner}:${group}" ]] \
            && pass "${file} ${mode} ${owner}:${group}" || warn "${file} is $(stat -c '%a %U:%G' "${file}")"
    done
}

### 16. Antivirus / Auditing ###

antivirus_audit() {
    header "Antivirus / Auditing"
    if confirm "Install ClamAV and update virus definitions?"; then
        apt install -y clamav clamav-daemon
        systemctl stop clamav-freshclam 2>/dev/null
        freshclam
        systemctl start clamav-freshclam 2>/dev/null
        log "Installed ClamAV and ran freshclam."
        if confirm "Scan /home now (only reports, nothing deleted)?"; then
            clamscan -r -i /home | tee -a "${LOG_FILE}"
        fi
    fi
    if confirm "Install and enable auditd?"; then
        apt install -y auditd && systemctl enable --now auditd && log "Enabled auditd."
    fi
    if confirm "Run a rootkit check with chkrootkit?"; then
        pkg_installed chkrootkit || apt install -y --no-install-recommends chkrootkit
        chkrootkit -q | tee -a "${LOG_FILE}"
    fi
}

verify_antivirus() {
    pkg_installed clamav && pass "ClamAV installed" || warn "ClamAV not installed"
    systemctl is-active --quiet auditd 2>/dev/null && pass "auditd running" || warn "auditd not running"
}

### Menu ###

SECTIONS=("System Updates" "User Management" "Password Audit" "Password Policy" "Firewall"
    "Login Screen (LightDM/GDM)" "SSH Hardening" "Sudoers Audit" "Prohibited Software"
    "Prohibited Media Files" "Game Software" "Services Review (report only)"
    "Kernel / Network (sysctl)" "Cron Jobs Review" "File Permissions" "Antivirus / Auditing")
FUNCS=(system_updates user_management password_audit password_policy firewall_setup
    login_screen ssh_hardening sudoers_audit prohibited_software
    prohibited_media game_software services_review
    kernel_hardening cron_review file_permissions antivirus_audit)
VERIFY=(verify_updates verify_users verify_passwords verify_policy verify_firewall
    verify_login verify_ssh verify_sudoers verify_software
    verify_media verify_games ""
    verify_kernel verify_cron verify_permissions verify_antivirus)

verification() {
    header "Verification"
    local i
    for i in "$@"; do
        [[ -n "${VERIFY[i - 1]}" ]] || continue
        echo "${SECTIONS[i - 1]}:"
        "${VERIFY[i - 1]}"
    done
}

show_menu() {
    local i
    echo ""
    echo "=================================================="
    echo "   CyberPatriot Hardening Menu"
    echo "=================================================="
    for i in "${!SECTIONS[@]}"; do
        printf "  %2d) %s\n" $((i + 1)) "${SECTIONS[i]}"
    done
    echo ""
    echo "   A) Run all          V) Verify everything"
    echo "   0) Exit"
}

main() {
    local choice i
    local -a picks
    log "=== CyberPatriot hardening script started ==="
    echo ""
    echo "REMINDER: Read the README and answer the forensic questions BEFORE making changes."

    while true; do
        show_menu
        read -r -p "Select section(s) (e.g. 1 3 9 or 2-4): " choice || break
        case "${choice,,}" in
            0 | q | exit) break ;;
            v) verification $(seq 1 "${#SECTIONS[@]}"); pause; continue ;;
            a) choice="all" ;;
        esac

        mapfile -t picks < <(parse_selection "${choice}" "${#SECTIONS[@]}")
        if ((${#picks[@]} == 0)); then
            echo "No valid selection."
            continue
        fi

        echo "Selected:"
        for i in "${picks[@]}"; do
            echo "  ${i}) ${SECTIONS[i - 1]}"
        done
        confirm "Run these now?" || continue

        for i in "${picks[@]}"; do
            log "Running: ${SECTIONS[i - 1]}"
            "${FUNCS[i - 1]}"
        done
        verification "${picks[@]}"
        pause
    done

    echo ""
    echo "Done. Full log: ${LOG_FILE}"
    log "=== CyberPatriot hardening script finished ==="
}

main
