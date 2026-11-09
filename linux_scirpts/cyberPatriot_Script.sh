#!/bin/bash

### CyberPatriot Ubuntu / Linux Mint Hardening Script ###

# Menu driven: pick a category, then the function(s) to run. Every change asks first.
# Read the README and answer the forensic questions BEFORE running anything.

set -uo pipefail

### Setup ###

LOG_FILE="./cyberpatriot_hardening.log"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LISTS_FILE="${SCRIPT_DIR}/cyberpatriot_lists.conf"
ADMIN_GROUPS="sudo|admin|wheel"
SEARCH_DIRS=(/home /root /tmp /srv /opt /media /mnt /var/www)
WEAK_PASSWORDS=(password Password Password1 password1 password123 123456 12345678 123456789
    qwerty abc123 letmein admin changeme welcome iloveyou P@ssw0rd Passw0rd monkey dragon
    football 111111 000000 root toor)
SESSION_START=0

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
info() { echo "  [INFO] $1"; }

backup_file() {
    local backup
    backup="$1.bak.$(date +%s)"
    cp -p "$1" "${backup}" && log "Backed up $1 to ${backup}."
}

restore_latest_backup() {
    local latest
    latest=$(ls -t "$1".bak.* 2>/dev/null | head -1)
    [[ -n "${latest}" ]] && cp -p "${latest}" "$1" && log "Restored $1 from ${latest}."
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

# Sets "key=value" options (vsftpd.conf).
set_eq_value() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^${key}=" "${file}"; then
        sed -i -E "s|^${key}=.*|${key}=${value}|" "${file}"
    elif grep -qE "^#[[:space:]]*${key}=" "${file}"; then
        sed -i -E "0,/^#[[:space:]]*${key}=.*/s||${key}=${value}|" "${file}"
    else
        echo "${key}=${value}" >> "${file}"
    fi
}

# Sets "key = value" options (faillock.conf).
set_spaced_value() {
    local file="$1" key="$2" value="$3"
    touch "${file}"
    if grep -qE "^${key}[[:space:]]*=" "${file}"; then
        sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
    elif grep -qE "^#[[:space:]]*${key}[[:space:]]*=" "${file}"; then
        sed -i -E "0,/^#[[:space:]]*${key}[[:space:]]*=.*/s||${key} = ${value}|" "${file}"
    else
        echo "${key} = ${value}" >> "${file}"
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

# Adds or updates key=value on the PAM line matching line_re.
set_pam_option() {
    local file="$1" line_re="$2" key="$3" value="$4"
    if grep -qE "${line_re}.*[[:space:]]${key}=" "${file}"; then
        sed -i -E "/${line_re}/ s/([[:space:]])${key}=[^[:space:]]*/\1${key}=${value}/" "${file}"
    else
        sed -i -E "/${line_re}/ s/$/ ${key}=${value}/" "${file}"
    fi
}

### Editable Lists ###

LIST_NAMES=(critical_services required_software authorized_admins authorized_users
    prohibited_services prohibited_software game_keywords media_types)
declare -A LIST_LABELS=(
    [critical_services]="Critical services (README)"
    [required_software]="Required software (README)"
    [authorized_admins]="Authorized administrators (README)"
    [authorized_users]="Authorized standard users (README)"
    [prohibited_services]="Services offered for disabling"
    [prohibited_software]="Packages offered for removal"
    [game_keywords]="Game name keywords"
    [media_types]="Media file extensions"
)
declare -A LISTS=()

default_list() {
    case "$1" in
        prohibited_services)
            echo "nginx apache2 squid dovecot smbd nmbd vsftpd pure-ftpd proftpd tftpd-hpa atftpd
                inetd xinetd telnet snmpd nfs-server nfs-kernel-server rpcbind bind9 named
                postfix sendmail exim4 cups avahi-daemon x11vnc vncserver mysql mariadb
                postgresql openvpn rsync" ;;
        prohibited_software)
            echo "john john-data hydra hydra-gtk nmap zenmap wireshark wireshark-qt wireshark-common
                tshark netcat netcat-traditional netcat-openbsd ncat aircrack-ng ophcrack ophcrack-cli
                ettercap-common ettercap-graphical kismet nikto sqlmap medusa fcrackzip hashcat doona
                xprobe xprobe2 nginx nginx-core apache2 squid dovecot-core dovecot-imapd dovecot-pop3d
                samba bind9 vsftpd pure-ftpd proftpd-basic proftpd-core tftpd atftpd tftpd-hpa x11vnc
                tightvncserver tigervnc-standalone-server vnc4server snmp snmpd nfs-kernel-server
                rpcbind sendmail sendmail-bin postfix xinetd telnetd telnet inetutils-telnetd
                rsh-server rsh-client nis deluge transmission-gtk transmission-daemon qbittorrent" ;;
        game_keywords)
            echo "aisleriot gnome-mines gnome-sudoku gnome-mahjongg gnome-chess gnome-robots
                gnome-nibbles gnome-tetravex gnome-klotski four-in-a-row iagno quadrapassel hitori
                lightsoff swell-foop tali five-or-more freeciv supertux minetest wesnoth steam
                openttd 0ad pingus frozen-bubble nethack bsdgames pacman kpat kmines ksudoku xboard
                gnuchess freecol extremetuxracer chromium-bsu neverball armagetron openarena
                warzone2100 lutris playonlinux minecraft solitaire tetris doom" ;;
        media_types)
            echo "mp3 mp4 wav flac avi mkv mov ogg m4a wma aac webm mpg mpeg" ;;
    esac | tr -s ' \n' '\n\n' | grep .
}

list_items() {
    [[ -n "${LISTS[$1]:-}" ]] && printf '%s\n' "${LISTS[$1]}"
}

list_has() {
    list_items "$1" | grep -qixF -- "$2"
}

# Regex like "^(a|b|c)" from a list, or one that never matches if the list is empty.
list_regex() {
    local joined
    joined=$(list_items "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g' | paste -sd'|')
    [[ -n "${joined}" ]] && echo "^(${joined})" || echo 'a^'
}

list_set() {
    LISTS[$1]=$(grep . <<< "$2" || true)
}

load_lists() {
    local name line section=""
    for name in "${LIST_NAMES[@]}"; do
        LISTS[$name]=$(default_list "${name}")
    done
    [[ -f "${LISTS_FILE}" ]] || { save_lists; return; }
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "${line}" ]] && continue
        if [[ "${line}" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            [[ -n "${LIST_LABELS[$section]:-}" ]] && LISTS[$section]="" || section=""
        elif [[ -n "${section}" ]]; then
            LISTS[$section]+="${LISTS[$section]:+$'\n'}${line}"
        fi
    done < "${LISTS_FILE}"
}

save_lists() {
    local name
    {
        echo "# CyberPatriot script lists - one entry per line under each [section]."
        echo "# Edit here or with 'L) Edit lists' in the script menu."
        for name in "${LIST_NAMES[@]}"; do
            echo ""
            echo "[${name}]"
            list_items "${name}"
        done
    } > "${LISTS_FILE}"
}

# Anything in the README critical/required lists is never offered for removal.
is_protected() {
    local name="${1%.service}" entry
    name="${name,,}"
    while IFS= read -r entry; do
        entry="${entry,,}"
        [[ -z "${entry}" ]] && continue
        [[ "${name}" == *"${entry}"* ]] && return 0
        ((${#name} >= 3)) && [[ "${entry}" == *"${name}"* ]] && return 0
    done < <(list_items critical_services; list_items required_software)
    return 1
}

protection_note() {
    if [[ -z "${LISTS[critical_services]:-}" ]]; then
        echo "NOTE: no critical services entered. Use S) README setup so required services are protected."
    fi
}

edit_one_list() {
    local name="$1" choice input entry i
    local -a items keep
    while true; do
        mapfile -t items < <(list_items "${name}")
        echo ""
        echo "[${name}] ${LIST_LABELS[$name]}"
        ((${#items[@]} == 0)) && echo "  (empty)"
        for i in "${!items[@]}"; do
            printf "  %3d) %s\n" $((i + 1)) "${items[i]}"
        done
        echo "  a) Add   r) Remove   d) Restore defaults   c) Clear   b) Back"
        read -r -p "> " choice || return
        case "${choice,,}" in
            a)
                read -r -p "Entries to add (space separated): " input
                for entry in ${input//,/ }; do
                    list_has "${name}" "${entry}" || LISTS[$name]+="${LISTS[$name]:+$'\n'}${entry}"
                done
                ;;
            r)
                read -r -p "Numbers to remove (e.g. 1 3 5-7): " input
                keep=("${items[@]}")
                for i in $(parse_selection "${input}" "${#items[@]}"); do
                    unset 'keep[i-1]'
                done
                list_set "${name}" "$(printf '%s\n' "${keep[@]}")"
                ;;
            d) confirm "Restore the default ${name} list?" && LISTS[$name]=$(default_list "${name}") ;;
            c) confirm "Clear the ${name} list?" && LISTS[$name]="" ;;
            b | "") return ;;
            *) continue ;;
        esac
        save_lists
    done
}

edit_lists() {
    local choice i
    while true; do
        header "Edit Lists"
        echo "Saved in ${LISTS_FILE}"
        for i in "${!LIST_NAMES[@]}"; do
            printf "  %d) %-22s %-38s (%d)\n" $((i + 1)) "${LIST_NAMES[i]}" \
                "${LIST_LABELS[${LIST_NAMES[i]}]}" "$(list_items "${LIST_NAMES[i]}" | grep -c .)"
        done
        echo "  b) Back"
        read -r -p "Choose a list: " choice || return
        [[ "${choice,,}" == "b" || -z "${choice}" ]] && return
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#LIST_NAMES[@]})); then
            edit_one_list "${LIST_NAMES[choice - 1]}"
        fi
    done
}

readme_setup() {
    header "README Setup"
    echo "Type what the README says (space separated)."
    echo "Enter = keep current value, '-' = clear it."
    local name input
    for name in critical_services required_software authorized_admins authorized_users; do
        echo ""
        echo "${LIST_LABELS[$name]}: $(list_items "${name}" | xargs)"
        read -r -p "  New value: " input
        case "${input}" in
            "") ;;
            -) LISTS[$name]="" ;;
            *) list_set "${name}" "$(tr ' ,' '\n\n' <<< "${input}")" ;;
        esac
    done
    save_lists
    echo ""
    echo "Saved. Protected from removal: $(list_items critical_services | xargs) $(list_items required_software | xargs)"
}

### 1. Users & Groups ###

readme_role() {
    [[ -z "${LISTS[authorized_admins]:-}${LISTS[authorized_users]:-}" ]] && return
    if list_has authorized_admins "$1"; then
        echo "admin"
    elif list_has authorized_users "$1"; then
        echo "standard"
    else
        echo "NOT IN README"
    fi
}

suggest_action() {
    case "$(readme_role "$1")" in
        admin) is_admin "$1" && echo k || echo a ;;
        standard) is_admin "$1" && echo s || echo k ;;
        "NOT IN README") echo d ;;
        *) echo k ;;
    esac
}

print_user_table() {
    local user uid shell admin
    printf "  %-18s %-7s %-18s %-6s %s\n" "USER" "UID" "SHELL" "ADMIN" "README SAYS"
    for user in root $(human_users); do
        uid=$(id -u "${user}")
        shell=$(getent passwd "${user}" | cut -d: -f7)
        admin="no"
        { is_admin "${user}" || [[ "${user}" == "root" ]]; } && admin="YES"
        printf "  %-18s %-7s %-18s %-6s %s\n" "${user}" "${uid}" "${shell}" "${admin}" \
            "$([[ "${user}" == "root" ]] || readme_role "${user}")"
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

create_user() {
    useradd -m -s /bin/bash "$1" && log "Created user $1."
    echo "  Set a password for $1:"
    passwd "$1"
}

user_management() {
    header "User Management"
    local -a users missing=()
    local user choice suggestion names name
    local me="${SUDO_USER:-root}"
    mapfile -t users < <(human_users)

    print_user_table
    echo ""
    echo "For each user: [k]eep, [a]dmin, [s]tandard user, [d]elete. Enter = suggested choice."
    for user in "${users[@]}"; do
        suggestion=$(suggest_action "${user}")
        read -r -p "  ${user} (suggested: ${suggestion}): " choice
        choice="${choice:-${suggestion}}"
        case "${choice,,}" in
            a) is_admin "${user}" || make_admin "${user}" ;;
            s) is_admin "${user}" && make_standard "${user}" ;;
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
    for name in $(list_items authorized_admins) $(list_items authorized_users); do
        id "${name}" >/dev/null 2>&1 || missing+=("${name}")
    done
    if ((${#missing[@]} > 0)) && confirm "README users missing from the system: ${missing[*]}. Create them?"; then
        for name in "${missing[@]}"; do
            create_user "${name}"
            list_has authorized_admins "${name}" && make_admin "${name}"
        done
    fi
    if confirm "Create any other users?"; then
        read -r -p "Usernames to create (space separated): " names
        for name in ${names}; do
            if id "${name}" >/dev/null 2>&1; then
                echo "  ${name} already exists."
                continue
            fi
            create_user "${name}"
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
    local others user role
    others=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | xargs)
    [[ -z "${others}" ]] && pass "Only root has UID 0" || warn "Other UID 0 accounts: ${others}"
    [[ -z "$(cut -d: -f3 /etc/passwd | sort | uniq -d)" ]] && pass "No duplicate UIDs" || warn "Duplicate UIDs found"
    passwd -S root | awk '{print $2}' | grep -q '^L' && pass "root account locked" || warn "root account not locked"
    for user in $(human_users); do
        role=$(readme_role "${user}")
        case "${role}" in
            "NOT IN README") warn "${user} is not in the README" ;;
            admin) is_admin "${user}" || warn "${user} should be an admin" ;;
            standard) is_admin "${user}" && warn "${user} should not be an admin" ;;
        esac
    done
    info "Admins: $(for u in $(human_users); do is_admin "$u" && printf '%s ' "$u"; done)"
}

show_groups() {
    getent group | awk -F: '$3 >= 1000 && $3 < 65534 {printf "  %-18s %s\n", $1, $4}'
}

group_members_change() {
    local action="$1" group user users
    read -r -p "Group name: " group
    getent group "${group}" >/dev/null || { echo "No group named '${group}'."; return; }
    read -r -p "Users to ${action} (space or comma separated): " users
    for user in ${users//,/ }; do
        id "${user}" >/dev/null 2>&1 || { echo "  No user named ${user}."; continue; }
        if [[ "${action}" == "add" ]]; then
            gpasswd -a "${user}" "${group}" >/dev/null && log "Added ${user} to group ${group}."
        else
            gpasswd -d "${user}" "${group}" >/dev/null && log "Removed ${user} from group ${group}."
        fi
    done
}

group_management() {
    header "Group Management"
    local choice group
    while true; do
        echo ""
        echo "Groups (GID 1000+) and members:"
        show_groups
        echo "  1) Create a group   2) Add users to a group   3) Remove users from a group"
        echo "  4) Delete a group   5) Show any group          b) Back"
        read -r -p "> " choice || return
        case "${choice,,}" in
            1)
                read -r -p "New group name: " group
                [[ -z "${group}" ]] && continue
                if getent group "${group}" >/dev/null; then
                    echo "Group ${group} already exists."
                elif confirm "Create group ${group}?"; then
                    groupadd "${group}" && log "Created group ${group}."
                fi
                ;;
            2) group_members_change add ;;
            3) group_members_change remove ;;
            4)
                read -r -p "Group to delete: " group
                getent group "${group}" >/dev/null && confirm "Delete group ${group}?" \
                    && groupdel "${group}" && log "Deleted group ${group}."
                ;;
            5)
                read -r -p "Group name: " group
                getent group "${group}" || echo "No group named '${group}'."
                ;;
            b | "") return ;;
        esac
    done
}

verify_groups() {
    info "Groups (GID 1000+) and members:"
    show_groups
}

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
        if [[ "${user}" == "root" ]] && confirm "Lock root instead of giving it a password?"; then
            passwd -l root && log "Locked root account."
        elif confirm "Change password for ${user}?"; then
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
                    echo "visudo check failed."
                    restore_latest_backup "${file}"
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

### 2. Password & Login Policy ###

UNIX_PW_LINE='^password.*pam_unix\.so'

password_policy() {
    header "Password Policy"
    local login_defs="/etc/login.defs"
    local common_pw="/etc/pam.d/common-password"
    local common_auth="/etc/pam.d/common-auth"
    local key opt backed_up=0

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
    fi
    if confirm "Apply max/min/warn password ages (90/10/7) to existing users?"; then
        for key in $(human_users); do
            chage -M 90 -m 10 -W 7 "${key}"
        done
        log "Applied password ages to existing users."
    fi

    echo ""
    grep -E "${UNIX_PW_LINE}" "${common_pw}"
    for opt in minlen=10 remember=5; do
        if confirm "Add ${opt} to the pam_unix line in ${common_pw}?"; then
            ((backed_up)) || { backup_file "${common_pw}"; backed_up=1; }
            set_pam_option "${common_pw}" "${UNIX_PW_LINE}" "${opt%%=*}" "${opt#*=}"
            log "Set ${opt} on pam_unix in ${common_pw}."
        fi
    done
    if [[ ! -f /etc/security/opasswd ]]; then
        touch /etc/security/opasswd && chmod 600 /etc/security/opasswd
    fi

    echo ""
    if confirm "Also enforce character classes with pam_pwquality (needs libpam-pwquality)?"; then
        pkg_installed libpam-pwquality || apt install -y libpam-pwquality
        if pkg_installed libpam-pwquality; then
            backup_file "${common_pw}"
            if ! grep -q "pam_pwquality.so" "${common_pw}"; then
                sed -i "0,/${UNIX_PW_LINE}/s//password\trequisite\t\t\tpam_pwquality.so retry=3\n&/" "${common_pw}"
            fi
            for opt in minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 difok=3; do
                set_pam_option "${common_pw}" "pam_pwquality\.so" "${opt%%=*}" "${opt#*=}"
            done
            log "Updated pam_pwquality settings in ${common_pw}."
        else
            echo "libpam-pwquality could not be installed, pwquality left unchanged."
        fi
    fi

    if grep -q "nullok" "${common_auth}" && confirm "Remove 'nullok' (blank password logins) from ${common_auth}?"; then
        backup_file "${common_auth}"
        sed -i -E 's/[[:space:]]+nullok(_secure)?//g' "${common_auth}"
        log "Removed nullok from ${common_auth}."
    fi
    echo ""
    grep -E "${UNIX_PW_LINE}|pam_pwquality" "${common_pw}"
}

verify_policy() {
    local key value
    for key in PASS_MAX_DAYS:90 PASS_MIN_DAYS:10 PASS_WARN_AGE:7; do
        value=$(awk -v k="${key%%:*}" '$1 == k {print $2}' /etc/login.defs)
        [[ "${value}" == "${key##*:}" ]] && pass "${key%%:*} = ${value}" || warn "${key%%:*} = ${value:-unset}"
    done
    for key in minlen remember; do
        grep -qE "${UNIX_PW_LINE}.*[[:space:]]${key}=" /etc/pam.d/common-password \
            && pass "pam_unix ${key} set" || warn "pam_unix ${key} not set"
    done
    grep -q "nullok" /etc/pam.d/common-auth && warn "nullok still in common-auth" || pass "nullok removed"
}

account_lockout() {
    header "Account Lockout (pam_faillock)"
    echo "Locks an account after repeated failed logins, using pam-auth-update profiles."
    if ! command -v pam-auth-update >/dev/null 2>&1; then
        echo "pam-auth-update not found, configure pam_faillock by hand."
        return
    fi
    if grep -q "pam_faillock" /etc/pam.d/common-auth; then
        echo "pam_faillock is already in common-auth:"
        grep "pam_faillock" /etc/pam.d/common-auth
        confirm "Rewrite the faillock profiles anyway?" || return
    elif ! confirm "Create faillock profiles and enable them?"; then
        return
    fi

    local f
    for f in /etc/pam.d/common-auth /etc/pam.d/common-password /etc/pam.d/common-account; do
        backup_file "${f}"
    done
    cat > /usr/share/pam-configs/faillock <<'EOF'
Name: Lockout on failed logins
Default: no
Priority: 0
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail
EOF
    cat > /usr/share/pam-configs/faillock_reset <<'EOF'
Name: Reset lockout on success
Default: no
Priority: 0
Auth-Type: Additional
Auth:
	required	pam_faillock.so authsucc
EOF
    cat > /usr/share/pam-configs/faillock_notify <<'EOF'
Name: Notify on account lockout
Default: no
Priority: 1024
Auth-Type: Primary
Auth:
	requisite	pam_faillock.so preauth
EOF
    DEBIAN_FRONTEND=noninteractive pam-auth-update --enable faillock faillock_reset faillock_notify \
        && log "Enabled pam_faillock lockout profiles."

    if confirm "Set lockout limits in /etc/security/faillock.conf (deny = 5, unlock_time = 900)?"; then
        [[ -f /etc/security/faillock.conf ]] && backup_file /etc/security/faillock.conf
        set_spaced_value /etc/security/faillock.conf deny 5
        set_spaced_value /etc/security/faillock.conf unlock_time 900
        log "Set faillock deny = 5, unlock_time = 900."
    fi
    echo ""
    grep -vE '^\s*(#|$)' /etc/pam.d/common-auth
    echo "Note: pam-auth-update keeps earlier hand edits (minlen, remember, nullok removal)."
}

verify_lockout() {
    grep -q "pam_faillock.so preauth" /etc/pam.d/common-auth && grep -q "pam_faillock.so authfail" /etc/pam.d/common-auth \
        && pass "pam_faillock lockout enabled" || warn "Account lockout not configured"
}

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

### 3. Updates ###

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
    if confirm "Run apt full-upgrade (can add/remove packages)?"; then
        apt full-upgrade -y && log "Ran apt full-upgrade."
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
    if command -v mintupdate-automation >/dev/null 2>&1 \
        && confirm "Enable Linux Mint Update Manager automatic updates?"; then
        mintupdate-automation upgrade enable && log "Enabled Mint automatic updates."
    fi
}

verify_updates() {
    local count
    count=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c .)
    ((count == 0)) && pass "No pending upgrades" || warn "${count} packages still upgradable"
    grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades \
        && pass "Automatic updates enabled" || warn "Automatic updates not enabled"
}

### 4. Network & Firewall ###

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
    echo "Check the README for which ports critical services need (e.g. 21 for FTP, 22 for SSH)."
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

ssh_hardening() {
    header "SSH Hardening"
    local sshd_config="/etc/ssh/sshd_config"
    local setting

    if ! pkg_installed openssh-server; then
        echo "openssh-server is not installed, nothing to do."
        return
    fi

    if ! is_protected openssh-server && ! confirm "Is SSH a required service in the README?"; then
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
        echo "sshd config test failed."
        restore_latest_backup "${sshd_config}"
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

SYSCTL_CONF="/etc/sysctl.conf"
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
    "net.ipv4.tcp_rfc1337 = 1"
    "kernel.randomize_va_space = 2"
)

# /etc/sysctl.conf loads last, so values go there to override anything else.
set_sysctl_value() {
    local key="$1" value="$2" key_re="${1//./\\.}"
    if grep -qE "^[[:space:]]*${key_re}[[:space:]]*=" "${SYSCTL_CONF}"; then
        sed -i -E "s|^[[:space:]]*${key_re}[[:space:]]*=.*|${key} = ${value}|" "${SYSCTL_CONF}"
    elif grep -qE "^#[[:space:]]*${key_re}[[:space:]]*=" "${SYSCTL_CONF}"; then
        sed -i -E "0,/^#[[:space:]]*${key_re}[[:space:]]*=.*/s||${key} = ${value}|" "${SYSCTL_CONF}"
    else
        echo "${key} = ${value}" >> "${SYSCTL_CONF}"
    fi
}

kernel_hardening() {
    header "Kernel / Network Hardening (sysctl)"
    local setting
    printf "  %-45s %s\n" "SETTING" "CURRENT"
    for setting in "${SYSCTL_SETTINGS[@]}"; do
        printf "  %-45s %s\n" "${setting}" "$(sysctl -n "${setting%% =*}" 2>/dev/null)"
    done
    if ! confirm "Write these settings to ${SYSCTL_CONF}?"; then
        return
    fi
    [[ -f "${SYSCTL_CONF}" ]] && backup_file "${SYSCTL_CONF}" || touch "${SYSCTL_CONF}"
    for setting in "${SYSCTL_SETTINGS[@]}"; do
        set_sysctl_value "${setting%% =*}" "${setting##*= }"
    done
    if confirm "Disable IPv6 too? (only if the README doesn't need it)"; then
        set_sysctl_value net.ipv6.conf.all.disable_ipv6 1
        set_sysctl_value net.ipv6.conf.default.disable_ipv6 1
        set_sysctl_value net.ipv6.conf.lo.disable_ipv6 1
    fi
    sysctl --system >/dev/null && log "Applied sysctl settings from ${SYSCTL_CONF}."
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

ftp_config() {
    header "FTP Server (vsftpd)"
    local conf="/etc/vsftpd.conf" mode root key
    if [[ ! -f "${conf}" ]]; then
        echo "vsftpd is not installed (${conf} not found)."
        return
    fi
    is_protected vsftpd || echo "Note: vsftpd is not in the critical services list. Check the README."
    echo "Current settings:"
    grep -E '^#?(anonymous_enable|local_enable|write_enable|anon_upload_enable|anon_mkdir_write_enable|anon_root|chroot_local_user|ssl_enable)=' "${conf}" | sed 's/^/  /'
    echo ""
    echo "What does the README want?"
    echo "  1) Anonymous logins only   2) Local user logins only   3) Skip"
    read -r -p "> " mode
    case "${mode}" in
        1)
            read -r -p "Anonymous FTP root (Enter = /var/ftp): " root
            root="${root:-/var/ftp}"
            [[ -d "${root}" ]] || echo "Warning: ${root} does not exist."
            confirm "Set anonymous_enable=YES, local_enable=NO, anon_root=${root}?" || return
            backup_file "${conf}"
            set_eq_value "${conf}" anonymous_enable YES
            set_eq_value "${conf}" local_enable NO
            set_eq_value "${conf}" anon_root "${root}"
            log "Configured vsftpd for anonymous logins only (anon_root=${root})."
            if confirm "Block anonymous uploads and new folders?"; then
                for key in anon_upload_enable anon_mkdir_write_enable; do
                    set_eq_value "${conf}" "${key}" NO
                done
                log "Blocked anonymous uploads in vsftpd."
            fi
            ;;
        2)
            confirm "Set anonymous_enable=NO, local_enable=YES, chroot_local_user=YES?" || return
            backup_file "${conf}"
            set_eq_value "${conf}" anonymous_enable NO
            set_eq_value "${conf}" local_enable YES
            set_eq_value "${conf}" chroot_local_user YES
            log "Configured vsftpd for local user logins only."
            ;;
        *) return ;;
    esac
    if confirm "Restart vsftpd to apply (it stays running)?"; then
        systemctl restart vsftpd
        if systemctl is-active --quiet vsftpd 2>/dev/null; then
            log "Restarted vsftpd."
        else
            echo "vsftpd failed to start!"
            restore_latest_backup "${conf}"
            systemctl restart vsftpd
        fi
    fi
}

verify_ftp() {
    [[ -f /etc/vsftpd.conf ]] || return
    systemctl is-active --quiet vsftpd 2>/dev/null && pass "vsftpd running" || warn "vsftpd is NOT running"
    info "$(grep -E '^(anonymous_enable|local_enable|anon_root)=' /etc/vsftpd.conf | xargs)"
}

### 5. Software & Services ###

# Prints "unit<TAB>state" for installed services that are on the prohibited list.
find_service_candidates() {
    local unit name active enabled
    {
        systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}'
        systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}'
    } | sort -u | while read -r unit; do
        name="${unit%.service}"
        list_has prohibited_services "${name}" || continue
        active=$(systemctl is-active "${unit}" 2>/dev/null)
        enabled=$(systemctl is-enabled "${unit}" 2>/dev/null)
        [[ "${active}" == "active" || "${enabled}" == "enabled" ]] || continue
        printf '%s\t%s/%s\n' "${unit}" "${active}" "${enabled}"
    done
}

disable_service() {
    local unit="$1"
    if is_protected "${unit}"; then
        echo "  ${unit} is a protected (critical) service, skipping."
        return
    fi
    systemctl disable --now "${unit}" && log "Disabled and stopped ${unit}."
    systemctl list-unit-files "${unit%.service}.socket" --no-legend 2>/dev/null | grep -q . \
        && systemctl disable --now "${unit%.service}.socket" 2>/dev/null
}

services_manage() {
    header "Services"
    protection_note
    echo "Listening ports:"
    ss -tulnp
    echo ""
    local -a rows units=() skipped=()
    local i row choice names name
    mapfile -t rows < <(find_service_candidates)
    for row in "${rows[@]}"; do
        if is_protected "${row%%$'\t'*}"; then
            skipped+=("${row%%$'\t'*}")
        else
            units+=("${row}")
        fi
    done
    ((${#skipped[@]} > 0)) && echo "Protected (not shown): ${skipped[*]}"

    if ((${#units[@]} == 0)); then
        echo "No services from the prohibited list are running or enabled."
    else
        echo "Services on the prohibited list (state = active/enabled):"
        for i in "${!units[@]}"; do
            printf "  %2d) %-30s %s\n" $((i + 1)) "${units[i]%%$'\t'*}" "${units[i]#*$'\t'}"
        done
        read -r -p "Numbers to DISABLE and stop (e.g. 1 3, all, Enter = none): " choice
        for i in $(parse_selection "${choice}" "${#units[@]}"); do
            name="${units[i - 1]%%$'\t'*}"
            confirm "Disable and stop ${name}?" && disable_service "${name}"
        done
    fi

    echo ""
    if confirm "Show all running services and disable others by name?"; then
        systemctl list-units --type=service --state=running --no-pager --no-legend --plain | awk '{print "  " $1}'
        read -r -p "Service names to disable (space separated, Enter = none): " names
        for name in ${names}; do
            [[ "${name}" == *.service ]] || name="${name}.service"
            confirm "Disable and stop ${name}?" && disable_service "${name}"
        done
    fi
}

verify_services() {
    local row name
    while IFS= read -r row; do
        [[ -z "${row}" ]] && continue
        name="${row%%$'\t'*}"
        is_protected "${name}" || warn "${name} still ${row#*$'\t'}"
    done < <(find_service_candidates)
    while IFS= read -r name; do
        systemctl list-unit-files "${name}.service" --no-legend 2>/dev/null | grep -q . || continue
        systemctl is-active --quiet "${name}" 2>/dev/null && pass "Critical service ${name} running" \
            || warn "CRITICAL service ${name} is NOT running"
    done < <(list_items critical_services)
}

# Prints "proto<TAB>port<TAB>pid" for each listening socket.
listeners() {
    local proto local_addr proc pid
    command -v ss >/dev/null 2>&1 || { echo "ss not found (install iproute2)." >&2; return; }
    ss -Htulnp 2>/dev/null | while read -r proto _ _ _ local_addr _ proc; do
        pid=$(grep -oE 'pid=[0-9]+' <<< "${proc}" | head -1 | cut -d= -f2)
        printf '%s\t%s\t%s\n' "${proto}" "${local_addr##*:}" "${pid:--}"
    done | sort -u -t$'\t' -k3,3 -k2,2n
}

# Script files in a process command line that no package owns.
unowned_scripts() {
    local arg
    for arg in $(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | cut -d' ' -f2-); do
        [[ -f "${arg}" ]] && ! dpkg -S "$(readlink -f "${arg}")" >/dev/null 2>&1 && readlink -f "${arg}"
    done
}

is_suspicious() {
    local pid="$1" comm exe
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null)
    [[ "${comm}" =~ ^(python|perl|ruby|php|nc|ncat|netcat|socat|bash|sh|dash|node|lua) ]] && return 0
    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
    [[ -n "${exe}" ]] && ! dpkg -S "${exe}" >/dev/null 2>&1
}

backdoor_check() {
    header "Backdoor / Listener Check"
    echo "Listening programs. '!!' = script interpreter, netcat, or a program no package installed."
    local -a rows scripts
    local i proto port pid cmd mark choice script ref
    mapfile -t rows < <(listeners)
    for i in "${!rows[@]}"; do
        IFS=$'\t' read -r proto port pid <<< "${rows[i]}"
        cmd=""
        [[ "${pid}" =~ ^[0-9]+$ ]] && cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
        mark="  "
        is_suspicious "${pid}" && mark="!!"
        printf "  %2d) %s %-4s %-6s pid %-7s %s\n" $((i + 1)) "${mark}" "${proto}" "${port}" "${pid}" "${cmd:0:80}"
    done
    ((${#rows[@]} == 0)) && { echo "  No listening sockets found."; return; }

    read -r -p "Numbers to STOP and investigate (Enter = none): " choice
    for i in $(parse_selection "${choice}" "${#rows[@]}"); do
        IFS=$'\t' read -r proto port pid <<< "${rows[i - 1]}"
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
        if is_protected "$(cat "/proc/${pid}/comm" 2>/dev/null)"; then
            echo "  ${cmd} is a protected (critical) service, skipping."
            continue
        fi
        mapfile -t scripts < <(unowned_scripts "${pid}")
        echo ""
        echo "Port ${port}: ${cmd}"
        ps -o pid=,ppid=,user=,args= -p "${pid}"
        for script in "${scripts[@]}"; do
            echo "  Files that mention ${script}:"
            grep -rlsF "${script}" /etc/systemd /lib/systemd/system /usr/lib/systemd/system /etc/cron* \
                /var/spool/cron /etc/rc.local /etc/init.d /etc/profile.d 2>/dev/null | sed 's/^/    /'
        done
        if confirm "Kill this process?"; then
            if ((${#scripts[@]} > 0)); then
                for script in "${scripts[@]}"; do
                    pkill -f -- "${script}"
                done
            fi
            kill "${pid}" 2>/dev/null
            sleep 1
            kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}"
            log "Stopped process ${pid} (${cmd}) listening on port ${port}."
        fi
        for script in "${scripts[@]}"; do
            if confirm "Delete ${script}?"; then
                rm -f -- "${script}" && log "Deleted backdoor file ${script}."
            fi
            for ref in $(grep -rlsF "${script}" /etc/systemd/system /lib/systemd/system 2>/dev/null); do
                confirm "Disable systemd unit $(basename "${ref}")?" && disable_service "$(basename "${ref}")"
            done
        done
    done
}

verify_backdoor() {
    local proto port pid bad=0
    while IFS=$'\t' read -r proto port pid; do
        [[ -z "${proto}" ]] && continue
        if is_suspicious "${pid}"; then
            warn "Suspicious listener on ${proto}/${port}: $(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
            bad=1
        fi
    done < <(listeners)
    ((bad == 0)) && pass "No suspicious listeners"
}

find_prohibited_packages() {
    dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
        | awk '$NF == "installed" {print $1}' | grep -ixF -f <(list_items prohibited_software; echo "__none__")
}

prohibited_software() {
    header "Prohibited Software"
    protection_note
    echo "Edit what counts as prohibited with L) Edit lists -> prohibited_software."
    local -a pkgs=() selected=() skipped=()
    local i choice pkg
    while IFS= read -r pkg; do
        if is_protected "${pkg}"; then skipped+=("${pkg}"); else pkgs+=("${pkg}"); fi
    done < <(find_prohibited_packages)
    ((${#skipped[@]} > 0)) && echo "Protected (not shown): ${skipped[*]}"
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
    local remaining pkg
    for pkg in $(find_prohibited_packages); do
        is_protected "${pkg}" || remaining+="${pkg} "
    done
    [[ -z "${remaining:-}" ]] && pass "No prohibited packages installed" \
        || warn "Still installed: ${remaining}"
}

# Prints "type<TAB>name" for every likely game found.
find_games() {
    local file pkg regex
    regex=$(list_regex game_keywords)
    {
        dpkg-query -W -f='${Section}\t${Package}\t${Status}\n' 2>/dev/null \
            | awk -F'\t' '$3 ~ / installed$/ && $1 ~ /games$/ {print "apt\t" $2}'
        dpkg-query -W -f='${Package}\t${Status}\n' 2>/dev/null \
            | awk -F'\t' '$2 ~ / installed$/ {print $1}' | grep -iE "${regex}" | sed 's/^/apt\t/'
        if command -v snap >/dev/null 2>&1; then
            snap list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -iE "${regex}" | sed 's/^/snap\t/'
        fi
        if command -v flatpak >/dev/null 2>&1; then
            flatpak list --app --columns=application 2>/dev/null | grep -iE "${regex#^}|game" | sed 's/^/flatpak\t/'
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
    } | sort -u | while IFS= read -r file; do
        is_protected "${file#*$'\t'}" || echo "${file}"
    done
}

game_software() {
    header "Game Software Detection"
    echo "Also lists loose files in /usr/games (e.g. archives of hacking tools)."
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
            file) confirm "Delete ${name}?" && rm -rf -- "${name}" && log "Deleted file ${name}." ;;
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

### 6. Files ###

# Public FTP folders hold work files the README protects.
ftp_dirs() {
    {
        printf '%s\n' /srv/ftp /var/ftp
        awk -F= '/^(anon_root|local_root)=/ {print $2}' /etc/vsftpd.conf 2>/dev/null
        getent passwd ftp | cut -d: -f6
    } | grep -E '^/.+' | sort -u
}

find_media() {
    local mode="${1:-normal}" ext dir
    local -a expr=() dirs=() prune=()
    for ext in $(list_items media_types); do
        expr+=(-o -iname "*.${ext}")
    done
    ((${#expr[@]} == 0)) && return
    while IFS= read -r dir; do
        prune+=(-o -path "${dir}")
        [[ "${mode}" == "ftp" && -d "${dir}" ]] && dirs+=("${dir}")
    done < <(ftp_dirs)
    if [[ "${mode}" == "ftp" ]]; then
        ((${#dirs[@]} > 0)) && find "${dirs[@]}" -type f \( "${expr[@]:1}" \) -print0 2>/dev/null
        return
    fi
    for dir in "${SEARCH_DIRS[@]}"; do
        [[ -d "${dir}" ]] && dirs+=("${dir}")
    done
    find "${dirs[@]}" \( "${prune[@]:1}" \) -prune -o -type f \( "${expr[@]:1}" \) -print0 2>/dev/null
}

prohibited_media() {
    header "Prohibited Media Files"
    if ! confirm "Does the README say media files are prohibited / scan for them?"; then
        return
    fi
    echo "File types (edit with L) Edit lists -> media_types): $(list_items media_types | xargs)"
    local extra i choice ftp_count
    read -r -p "Extra extensions for this scan only (space separated, Enter = none): " extra
    for i in ${extra}; do
        LISTS[media_types]+=$'\n'"${i#.}"
    done

    local -a files selected=()
    mapfile -d '' files < <(find_media)
    ftp_count=$(find_media ftp | tr -cd '\0' | wc -c)
    load_lists
    ((ftp_count > 0)) && echo "Skipped ${ftp_count} file(s) in FTP folders ($(ftp_dirs | xargs)). Deleting those can cost points."
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
    ((count == 0)) && pass "No media files found (outside FTP folders)" || warn "${count} media files remain (OK if allowed)"
}

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

### 7. Malware & Auditing ###

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

### 8. Forensics Helper (read-only) ###

forensic_ports() {
    header "Listening Ports and Processes"
    ss -tulnp
    echo ""
    local pid
    for pid in $(ss -Htulnp 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un); do
        ps -o pid=,ppid=,user=,args= -p "${pid}"
    done
}

forensic_find() {
    header "Find Files"
    local pattern
    read -r -p "File name or pattern (e.g. override.txt, *.zip): " pattern
    [[ -z "${pattern}" ]] && return
    [[ "${pattern}" == *[*?]* ]] || pattern="*${pattern}*"
    find / \( -path /proc -o -path /sys -o -path /run -o -path /dev -o -path /snap \) -prune \
        -o -iname "${pattern}" -print 2>/dev/null | head -200
}

forensic_base64() {
    header "Base64 Decode"
    local input
    read -r -p "Base64 text or a file path: " input
    [[ -z "${input}" ]] && return
    if [[ -f "${input}" ]]; then
        base64 -d < "${input}"
    else
        base64 -d <<< "${input}"
    fi
    echo ""
}

forensic_hash() {
    header "File Hashes"
    local file
    read -r -p "File path: " file
    [[ -f "${file}" ]] || { echo "No such file."; return; }
    md5sum "${file}"
    sha1sum "${file}"
    sha256sum "${file}"
}

forensic_lookup() {
    header "User / Group Lookup"
    local name
    read -r -p "User or group name: " name
    [[ -z "${name}" ]] && return
    if id "${name}" >/dev/null 2>&1; then
        id "${name}"
        getent passwd "${name}"
        passwd -S "${name}"
        chage -l "${name}"
    fi
    getent group "${name}" && echo "(group: name:x:GID:members)"
}

forensic_recent() {
    header "Recently Modified Files"
    local days
    read -r -p "Modified in the last how many days? (Enter = 7): " days
    [[ "${days:-7}" =~ ^[0-9]+$ ]] || return
    find /home /root /tmp /srv /opt /var/www /usr/games -type f -mtime -"${days:-7}" \
        -not -path '*/.cache/*' -printf '%TY-%Tm-%Td %TH:%TM  %-10u %p\n' 2>/dev/null | sort -r | head -60
}

### Menu ###

CATEGORIES=("Users & Groups" "Password & Login Policy" "Updates" "Network & Firewall"
    "Software & Services" "Files" "Malware & Auditing" "Forensics Helper (read-only)")
CAT_FUNCS=(
    "user_management group_management password_audit sudoers_audit"
    "password_policy account_lockout login_screen"
    "system_updates"
    "firewall_setup ssh_hardening kernel_hardening ftp_config"
    "services_manage backdoor_check prohibited_software game_software"
    "prohibited_media cron_review file_permissions"
    "antivirus_audit"
    "forensic_ports forensic_find forensic_base64 forensic_hash forensic_lookup forensic_recent"
)
declare -A TITLE=(
    [user_management]="User Management" [group_management]="Group Management"
    [password_audit]="Password Audit" [sudoers_audit]="Sudoers Audit"
    [password_policy]="Password Policy" [account_lockout]="Account Lockout"
    [login_screen]="Login Screen (LightDM/GDM)" [system_updates]="System Updates"
    [firewall_setup]="Firewall" [ssh_hardening]="SSH Hardening"
    [kernel_hardening]="Kernel / Network (sysctl)" [ftp_config]="FTP Server (vsftpd)"
    [services_manage]="Services" [backdoor_check]="Backdoor / Listener Check"
    [prohibited_software]="Prohibited Software" [game_software]="Game Software"
    [prohibited_media]="Prohibited Media Files" [cron_review]="Cron Jobs Review"
    [file_permissions]="File Permissions" [antivirus_audit]="Antivirus / Auditing"
    [forensic_ports]="Listening Ports and Processes" [forensic_find]="Find Files"
    [forensic_base64]="Base64 Decode" [forensic_hash]="File Hashes"
    [forensic_lookup]="User / Group Lookup" [forensic_recent]="Recently Modified Files"
)
declare -A VERIFY_FN=(
    [user_management]=verify_users [group_management]=verify_groups
    [password_audit]=verify_passwords [sudoers_audit]=verify_sudoers
    [password_policy]=verify_policy [account_lockout]=verify_lockout
    [login_screen]=verify_login [system_updates]=verify_updates
    [firewall_setup]=verify_firewall [ssh_hardening]=verify_ssh
    [kernel_hardening]=verify_kernel [ftp_config]=verify_ftp
    [services_manage]=verify_services [backdoor_check]=verify_backdoor
    [prohibited_software]=verify_software [game_software]=verify_games
    [prohibited_media]=verify_media [cron_review]=verify_cron
    [file_permissions]=verify_permissions [antivirus_audit]=verify_antivirus
)

verification() {
    local fn checker
    header "Verification"
    for fn in "$@"; do
        checker="${VERIFY_FN[$fn]:-}"
        [[ -n "${checker}" ]] || continue
        echo "${TITLE[$fn]}:"
        "${checker}"
    done
}

verify_all() {
    local -a all=() fns
    local group
    for group in "${CAT_FUNCS[@]}"; do
        read -ra fns <<< "${group}"
        all+=("${fns[@]}")
    done
    verification "${all[@]}"
}

run_functions() {
    local fn
    for fn in "$@"; do
        log "Running: ${TITLE[$fn]}"
        "${fn}"
    done
    verification "$@"
    pause
}

category_menu() {
    local idx="$1" choice i
    local -a fns picks
    read -ra fns <<< "${CAT_FUNCS[idx]}"
    while true; do
        echo ""
        echo "=================================================="
        echo "   ${CATEGORIES[idx]}"
        echo "=================================================="
        for i in "${!fns[@]}"; do
            printf "  %d) %s\n" $((i + 1)) "${TITLE[${fns[i]}]}"
        done
        echo ""
        echo "  a) Run all in this category   b) Back"
        read -r -p "Select function(s) (e.g. 1 or 1 3): " choice || return
        case "${choice,,}" in
            b | "") return ;;
            a) choice="all" ;;
        esac
        mapfile -t picks < <(parse_selection "${choice}" "${#fns[@]}")
        if ((${#picks[@]} == 0)); then
            echo "No valid selection."
            continue
        fi
        if ((${#picks[@]} > 1)); then
            echo "Selected:"
            for i in "${picks[@]}"; do
                echo "  ${i}) ${TITLE[${fns[i - 1]}]}"
            done
            confirm "Run these now?" || continue
        fi
        local -a chosen=()
        for i in "${picks[@]}"; do
            chosen+=("${fns[i - 1]}")
        done
        run_functions "${chosen[@]}"
    done
}

show_main_menu() {
    local i
    echo ""
    echo "=================================================="
    echo "   CyberPatriot Hardening Menu"
    echo "=================================================="
    for i in "${!CATEGORIES[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "${CATEGORIES[i]}"
    done
    echo ""
    echo "  S) README setup     L) Edit lists"
    echo "  V) Verify all       0) Exit"
}

change_summary() {
    header "Changes Made This Run"
    local changes
    changes=$(tail -n +$((SESSION_START + 1)) "${LOG_FILE}" 2>/dev/null \
        | grep -E '^\[' | grep -vE 'Backed up|Running:|===')
    if [[ -n "${changes}" ]]; then
        echo "${changes}"
    else
        echo "No changes were made."
    fi
}

main() {
    local choice
    load_lists
    [[ -f "${LOG_FILE}" ]] && SESSION_START=$(wc -l < "${LOG_FILE}")
    log "=== CyberPatriot hardening script started ==="
    echo ""
    echo "REMINDER: Read the README and answer the forensic questions BEFORE making changes."
    echo "Lists file: ${LISTS_FILE}"
    if confirm "Enter README info now (critical services, required software, authorized users)?"; then
        readme_setup
    fi

    while true; do
        show_main_menu
        read -r -p "Select a category: " choice || break
        case "${choice,,}" in
            0 | q | exit) break ;;
            s) readme_setup ;;
            l) edit_lists ;;
            v) verify_all; pause ;;
            *)
                if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#CATEGORIES[@]})); then
                    category_menu $((choice - 1))
                else
                    echo "No valid selection."
                fi
                ;;
        esac
    done

    change_summary
    echo ""
    echo "Full log: ${LOG_FILE}"
    log "=== CyberPatriot hardening script finished ==="
}

main
