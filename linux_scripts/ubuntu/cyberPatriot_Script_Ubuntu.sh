#!/bin/bash

### CyberPatriot Ubuntu / Linux Mint Hardening Script ###

# Menu driven: pick a category, then the function(s) to run. Every change asks first.
# Read the README and answer the forensic questions BEFORE running anything.

set -uo pipefail

### Setup ###

LOG_FILE="./cyberpatriot_hardening.log"
ADMIN_GROUPS="sudo|admin|wheel"
SEARCH_DIRS=(/home /root /tmp /srv /opt /media /mnt /var/www)
WEAK_PASSWORDS=(password Password Password1 password1 password123 123456 12345678 123456789
    qwerty abc123 letmein admin changeme welcome iloveyou P@ssw0rd Passw0rd monkey dragon
    football 111111 000000 root toor)
MEDIA_EXTS=(mp3 mp4 wav flac avi mkv mov ogg m4a wma aac webm mpg mpeg)
GAME_KEYWORDS="aisleriot|gnome-mines|gnome-sudoku|gnome-mahjongg|gnome-chess|gnome-robots|gnome-nibbles|gnome-tetravex|gnome-klotski|four-in-a-row|iagno|quadrapassel|hitori|lightsoff|swell-foop|tali|five-or-more|freeciv|supertux|minetest|wesnoth|steam|openttd|0ad|pingus|frozen-bubble|nethack|bsdgames|pacman|kpat|kmines|ksudoku|xboard|gnuchess|freecol|extremetuxracer|chromium-bsu|neverball|armagetron|openarena|warzone2100|lutris|playonlinux|minecraft|solitaire|tetris|doom"
SESSION_START=0

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try: sudo ./cyberPatriot_Script_Ubuntu.sh)"
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

# Prints the package that owns a file. Tries the /usr and non-/usr spelling of the path.
pkg_owner() {
    local path="$1" alt out
    case "${path}" in
        /usr/bin/* | /usr/sbin/* | /usr/lib*) alt="${path#/usr}" ;;
        /bin/* | /sbin/* | /lib*) alt="/usr${path}" ;;
        *) alt="" ;;
    esac
    out=$(dpkg -S "${path}" 2>/dev/null) || { [[ -n "${alt}" ]] && out=$(dpkg -S "${alt}" 2>/dev/null); } || return 1
    head -1 <<< "${out}" | cut -d: -f1
}

# Prints the input, or "(none found)" when there is none.
or_none() {
    local out
    out=$(cat)
    if [[ -n "${out}" ]]; then echo "${out}"; else echo "  (none found)"; fi
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

os_value() {
    sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d '"' | head -1
}

check_os() {
    local id like
    id=$(os_value ID)
    like=$(os_value ID_LIKE)
    [[ "${id}" == "ubuntu" || "${like}" == *ubuntu* ]] && return
    echo "WARNING: this script is for Ubuntu / Linux Mint, but this system reports '${id:-unknown}'."
    [[ "${id}" == "debian" || "${like}" == *debian* ]] && echo "Use linux_scripts/debian/cyberPatriot_Script_Debian.sh instead."
    confirm "Continue anyway?" || exit 1
}

sudo_admins() {
    getent group sudo | cut -d: -f4 | tr ',' ' ' | xargs
}

is_last_admin() {
    [[ "$(sudo_admins)" == "$1" ]]
}

### Keep Decisions ###

# Things answered "keep" this run, so later checks and functions leave them alone.
declare -A KEPT=()

mark_kept() {
    local name
    for name in "$@"; do
        [[ -n "${name}" ]] && KEPT[${name%.service}]=1
    done
}

is_kept() {
    [[ -n "${1:-}" && -n "${KEPT[${1%.service}]:-}" ]]
}

### 1. Users & Groups ###

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

# Describes what an account is right now, e.g. "ADMIN (sudo, adm)".
user_role_text() {
    local groups
    groups=$(id -nG "$1" | tr ' ' '\n' | grep -xE "sudo|adm|admin|wheel" | paste -sd, | sed 's/,/, /g')
    if is_admin "$1"; then
        echo "ADMIN (${groups})"
    elif [[ -n "${groups}" ]]; then
        echo "standard user (in ${groups})"
    else
        echo "standard user"
    fi
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
    useradd -m -s /bin/bash "$1" || { echo "  Could not create $1."; return 1; }
    log "Created user $1."
    echo "  Set a password for $1 (12+ characters):"
    passwd "$1"
    if confirm "  Must $1 change this password at next login?"; then
        passwd -e "$1" >/dev/null && log "Set $1 to change password at next login."
    fi
}

delete_user() {
    local user="$1"
    if pgrep -u "${user}" >/dev/null 2>&1; then
        echo "  ${user} has running programs (may be logged in)."
        confirm "  Stop them so the account can be deleted?" && pkill -KILL -u "${user}" && sleep 1
    fi
    userdel -r "${user}" 2>/dev/null || userdel "${user}" 2>/dev/null
    if id "${user}" >/dev/null 2>&1; then
        echo "  Could not delete ${user}."
    else
        log "Deleted user ${user}."
    fi
}

# Lists the human users by number and prints the ones chosen.
pick_users() {
    local -a users
    local i choice
    mapfile -t users < <(human_users)
    for i in "${!users[@]}"; do
        printf "  %2d) %s\n" $((i + 1)) "${users[i]}" >&2
    done
    read -r -p "$1 (e.g. 1 3, all, Enter = none): " choice
    for i in $(parse_selection "${choice}" "${#users[@]}"); do
        echo "${users[i - 1]}"
    done
}

user_management() {
    header "User Review"
    local -a users
    local user choice names name
    local me="${SUDO_USER:-root}"
    mapfile -t users < <(human_users)

    print_user_table
    echo ""
    echo "For each user decide: [a]dmin, [u]ser (standard), [x] unauthorized (delete). Enter = leave as is."
    for user in "${users[@]}"; do
        echo ""
        echo "  ${user} (UID $(id -u "${user}")) - currently: $(user_role_text "${user}")$([[ "${user}" == "${me}" ]] && echo ' (you are logged in as this user)')"
        read -r -p "  Should be [a/u/x]: " choice
        case "${choice,,}" in
            a) is_admin "${user}" && echo "  Already an admin." || make_admin "${user}" ;;
            u)
                if ! is_admin "${user}"; then
                    echo "  Already a standard user."
                elif ! is_last_admin "${user}" || confirm "  ${user} is the LAST admin. Remove admin rights anyway?"; then
                    make_standard "${user}"
                fi
                ;;
            x)
                if [[ "${user}" == "${me}" ]]; then
                    echo "  Refusing to delete ${user}, you are logged in as this user."
                elif is_last_admin "${user}" && ! confirm "  ${user} is the LAST admin. Delete anyway?"; then
                    continue
                elif confirm "  Really delete ${user} and their home directory?"; then
                    delete_user "${user}"
                fi
                ;;
            *) ;;
        esac
    done

    echo ""
    if confirm "Create any users from the README that are missing?"; then
        read -r -p "Usernames to create (space separated): " names
        for name in ${names}; do
            if id "${name}" >/dev/null 2>&1; then
                echo "  ${name} already exists."
                continue
            fi
            create_user "${name}" || continue
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
    info "Admins: $(for u in $(human_users); do is_admin "$u" && printf '%s ' "$u"; done)"
    info "Standard users: $(for u in $(human_users); do is_admin "$u" || printf '%s ' "$u"; done)"
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
    [[ ${#pw} -ge 12 && "${pw}" =~ [A-Z] && "${pw}" =~ [a-z] && "${pw}" =~ [0-9] && "${pw}" =~ [^A-Za-z0-9] ]]
}

prompt_new_password() {
    local pw
    while true; do
        read -r -s -p "New password (Enter = Cyb3rPatr!0t\$): " pw
        echo "" >&2
        pw="${pw:-Cyb3rPatr!0t\$}"
        meets_policy "${pw}" && break
        echo "Password must be 12+ characters with upper, lower, number and symbol." >&2
    done
    printf '%s' "${pw}"
}

password_audit() {
    header "Password Audit"
    echo "Checks for empty, weak-hash, common/guessable and expired passwords."
    echo "Passwords that pass these checks are left alone."
    echo ""
    local -a flagged=()
    local user issue status new_pw=""
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

    echo ""
    if ((${#flagged[@]} == 0)); then
        echo "No insecure passwords detected."
    else
        new_pw=$(prompt_new_password)
    fi

    for user in "${flagged[@]}"; do
        if [[ "${user}" == "root" ]] && confirm "Lock root instead of giving it a password?"; then
            passwd -l root && log "Locked root account."
        elif confirm "Change password for ${user}?"; then
            echo "${user}:${new_pw}" | chpasswd && log "Changed password for ${user}."
        fi
    done

    echo ""
    echo "The script can't see passwords the README lists. Short ones (under 12 characters) should be changed."
    if confirm "Reset the password of any other users?"; then
        for user in $(pick_users "Users to reset"); do
            [[ -n "${new_pw}" ]] || new_pw=$(prompt_new_password)
            echo "${user}:${new_pw}" | chpasswd && log "Changed password for ${user}."
        done
    fi
    if confirm "Make any users change their password at next login?"; then
        for user in $(pick_users "Users who must change it"); do
            passwd -e "${user}" >/dev/null && log "Set ${user} to change password at next login."
        done
    fi
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
    for opt in minlen=12 remember=5; do
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
            for opt in minlen=12 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 difok=3; do
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
    value=$(grep -E "${UNIX_PW_LINE}|pam_pwquality\.so" /etc/pam.d/common-password | grep -oE 'minlen=[0-9]+' | cut -d= -f2 | sort -n | tail -1)
    [[ -n "${value}" ]] && ((value < 12)) && warn "Minimum password length is ${value} (12 or more is expected)"
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

# sshd_config lines that apply to everyone (before the first Match block).
sshd_global_lines() {
    sed -E '/^[[:space:]]*Match[[:space:]]/I,$d' "$1"
}

# sshd keywords ignore case and the first value wins, so every global copy is changed.
set_sshd_value() {
    local file="$1" key="$2" value="$3"
    if sshd_global_lines "${file}" | grep -qiE "^[[:space:]]*${key}[[:space:]]"; then
        sed -i -E "1,/^[[:space:]]*Match[[:space:]]/I s|^[[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "${file}"
    elif grep -qiE "^#[[:space:]]*${key}[[:space:]]" "${file}"; then
        sed -i -E "0,/^#[[:space:]]*${key}[[:space:]]/I s|^#[[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "${file}"
    elif grep -qiE "^[[:space:]]*Match[[:space:]]" "${file}"; then
        sed -i -E "0,/^[[:space:]]*Match[[:space:]]/I s|^([[:space:]]*Match[[:space:]])|${key} ${value}\n\1|I" "${file}"
    else
        echo "${key} ${value}" >> "${file}"
    fi
}

ssh_hardening() {
    header "SSH Hardening"
    local sshd_config="/etc/ssh/sshd_config"
    local setting key value file current

    if ! pkg_installed openssh-server; then
        echo "openssh-server is not installed, nothing to do."
        return
    fi

    if ! is_kept openssh-server && ! is_kept ssh && ! confirm "Is SSH a required service in the README?"; then
        if confirm "Stop and remove openssh-server?"; then
            systemctl disable --now ssh 2>/dev/null
            apt purge -y openssh-server && log "Removed openssh-server."
        fi
        return
    fi
    mark_kept ssh openssh-server

    backup_file "${sshd_config}"
    for setting in "PermitRootLogin no" "PermitEmptyPasswords no" "LoginGraceTime 60" "MaxAuthTries 4" \
        "X11Forwarding no" "IgnoreRhosts yes" "HostbasedAuthentication no" "PermitUserEnvironment no" \
        "UsePAM yes" "PasswordAuthentication yes"; do
        key="${setting%% *}"
        value="${setting#* }"
        confirm "Set '${setting}'?" || continue
        set_sshd_value "${sshd_config}" "${key}" "${value}"
        log "Set ${setting} in ${sshd_config}."
        # Files in sshd_config.d are read first, so a different value there would win.
        for file in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "${file}" ]] || continue
            current=$(sshd_global_lines "${file}" | grep -iE "^[[:space:]]*${key}[[:space:]]" | head -1)
            [[ -z "${current}" ]] && continue
            [[ "${current,,}" =~ ^[[:space:]]*${key,,}[[:space:]]+${value,,}[[:space:]]*$ ]] && continue
            echo "  ${file} overrides it with: ${current}"
            if confirm "  Change it there too?"; then
                backup_file "${file}"
                set_sshd_value "${file}" "${key}" "${value}"
                log "Set ${setting} in ${file}."
            fi
        done
    done

    mkdir -p /run/sshd
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
    mkdir -p /run/sshd
    effective=$(sshd -T 2>/dev/null)
    grep -qi "^permitrootlogin no" <<< "${effective}" && pass "PermitRootLogin no" || warn "Root login allowed over SSH"
    grep -qi "^permitemptypasswords no" <<< "${effective}" && pass "PermitEmptyPasswords no" || warn "Empty passwords allowed over SSH"
    grep -qi "^x11forwarding no" <<< "${effective}" && pass "X11Forwarding no" || warn "X11Forwarding enabled"
}

# Newer releases may not ship /etc/sysctl.conf; then a drop-in that sorts last is used.
if [[ -f /etc/sysctl.conf ]]; then
    SYSCTL_CONF="/etc/sysctl.conf"
else
    SYSCTL_CONF="/etc/sysctl.d/99-zz-cyberpatriot.conf"
fi
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

# Values go to SYSCTL_CONF, which loads last, so they override anything else.
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

# Shows other /etc/sysctl.d files that set the same keys differently and offers to fix them.
fix_sysctl_dropins() {
    local file setting key want key_re
    local -a hits=()
    for file in /etc/sysctl.d/*.conf; do
        [[ -f "${file}" && ! -L "${file}" && "${file}" != "${SYSCTL_CONF}" ]] || continue
        for setting in "${SYSCTL_SETTINGS[@]}"; do
            key="${setting%% =*}"
            want="${setting##*= }"
            key_re="${key//./\\.}"
            grep -qE "^[[:space:]]*${key_re}[[:space:]]*=" "${file}" || continue
            grep -qE "^[[:space:]]*${key_re}[[:space:]]*=[[:space:]]*${want}[[:space:]]*$" "${file}" && continue
            hits+=("${file}|${key}|${want}")
            echo "  ${file}: $(grep -E "^[[:space:]]*${key_re}[[:space:]]*=" "${file}" | head -1)   (want ${want})"
        done
    done
    ((${#hits[@]} == 0)) && return
    echo "${SYSCTL_CONF} loads last, so the values above are already overridden."
    confirm "Fix those lines in their own files too?" || return
    for setting in "${hits[@]}"; do
        IFS='|' read -r file key want <<< "${setting}"
        key_re="${key//./\\.}"
        [[ -f "${file}.bak.fixed" ]] || { cp -p "${file}" "${file}.bak.fixed"; log "Backed up ${file} to ${file}.bak.fixed."; }
        sed -i -E "s|^[[:space:]]*${key_re}[[:space:]]*=.*|${key} = ${want}|" "${file}"
        log "Fixed ${key} in ${file}."
    done
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
    fix_sysctl_dropins
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
    is_kept vsftpd || echo "Check the README: if vsftpd is a critical service, configure it but never stop it."
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

# Services the review looks for: "name|what it is".
SERVICE_CANDIDATES=(
    "nginx|Web server (hosts websites)"
    "apache2|Web server (hosts websites)"
    "squid|Web proxy (passes web traffic through itself)"
    "dovecot|Email mailbox server (POP3/IMAP)"
    "postfix|Email sending server (SMTP)"
    "sendmail|Email sending server (SMTP)"
    "exim4|Email sending server (SMTP)"
    "smbd|Samba Windows-style file sharing"
    "nmbd|Samba name service"
    "vsftpd|FTP file server"
    "pure-ftpd|FTP file server"
    "proftpd|FTP file server"
    "tftpd-hpa|TFTP file transfer with no password"
    "atftpd|TFTP file transfer with no password"
    "inetd|Old super-server that starts telnet and similar"
    "xinetd|Old super-server that starts telnet and similar"
    "ssh|SSH remote login server"
    "snmpd|SNMP network monitoring (leaks system info)"
    "nfs-server|NFS Unix file sharing"
    "rpcbind|RPC helper used by NFS"
    "bind9|DNS server"
    "named|DNS server"
    "cups|Printing service"
    "avahi-daemon|Announces this computer on the local network"
    "x11vnc|VNC remote desktop"
    "vncserver|VNC remote desktop"
    "mysql|MySQL database"
    "mariadb|MariaDB database"
    "postgresql|PostgreSQL database"
    "openvpn|VPN tunnel"
    "rsync|rsync file sync daemon"
)

# Packages the review looks for (hacking tools, servers, file sharing, torrents).
PACKAGE_CANDIDATES=(john john-data hydra hydra-gtk nmap zenmap wireshark wireshark-qt
    wireshark-common tshark netcat netcat-traditional netcat-openbsd ncat aircrack-ng ophcrack
    ophcrack-cli ettercap-common ettercap-graphical kismet nikto sqlmap medusa fcrackzip hashcat
    doona xprobe xprobe2 nginx nginx-core apache2 squid dovecot-core dovecot-imapd dovecot-pop3d
    samba bind9 vsftpd pure-ftpd proftpd-basic proftpd-core tftpd atftpd tftpd-hpa x11vnc
    tightvncserver tigervnc-standalone-server vnc4server snmp snmpd nfs-kernel-server rpcbind
    sendmail sendmail-bin postfix xinetd telnetd telnet inetutils-telnetd rsh-server rsh-client
    nis deluge transmission-gtk transmission-daemon qbittorrent)

service_package() {
    local unit_file
    unit_file=$(systemctl show -p FragmentPath --value "$1" 2>/dev/null)
    { [[ -n "${unit_file}" ]] && pkg_owner "${unit_file}"; } || pkg_owner "/etc/init.d/${1%.service}"
}

service_found() {
    local active enabled
    active=$(systemctl is-active "$1" 2>/dev/null)
    enabled=$(systemctl is-enabled "$1" 2>/dev/null)
    [[ "${active}" == "active" || "${enabled}" == "enabled" ]] && echo "${active}/${enabled}"
}

find_candidate_packages() {
    dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | awk '$NF == "installed" {print $1}' \
        | grep -xF -f <(printf '%s\n' "${PACKAGE_CANDIDATES[@]}")
}

remove_game_item() {
    local type="$1" name="$2"
    case "${type}" in
        apt) apt purge "${name}" && log "Purged game package ${name}." ;;
        snap) snap remove "${name}" && log "Removed snap ${name}." ;;
        flatpak) flatpak uninstall -y "${name}" && log "Removed flatpak ${name}." ;;
        file) rm -rf -- "${name}" && log "Deleted file ${name}." ;;
    esac
}

software_review() {
    header "Applications & Services Review"
    echo "Each item found on this machine is shown with what it does."
    echo "Check the README: keep critical services and required software (e.g. the required browser)."
    echo "Removing or stopping something the README requires costs points."
    local -a kept=() disabled=() removed=() handled=() kept_services=() games
    local row name desc unit state pkg choice item type names covered

    echo ""
    echo "--- Services ---"
    for row in "${SERVICE_CANDIDATES[@]}"; do
        IFS='|' read -r name desc <<< "${row}"
        unit="${name}.service"
        state=$(service_found "${unit}") || continue
        pkg=$(service_package "${unit}")
        [[ -n "${pkg}" ]] && handled+=("${pkg}")
        echo ""
        echo "  ${name}: ${desc}"
        echo "    state: ${state}${pkg:+   package: ${pkg}}"
        read -r -p "    [k]eep  [d]isable (stop it)  [r]emove (stop + uninstall)  (Enter = keep): " choice
        case "${choice,,}" in
            d) disable_service "${unit}"; disabled+=("${name}") ;;
            r)
                disable_service "${unit}"
                if [[ -n "${pkg}" ]] && apt purge "${pkg}"; then
                    log "Purged package ${pkg}."
                    removed+=("${name}")
                else
                    echo "    Not uninstalled; ${name} is stopped and disabled."
                    disabled+=("${name}")
                fi
                ;;
            *) mark_kept "${name}" "${pkg}"; kept+=("${name}") ;;
        esac
    done
    ((${#kept[@]} + ${#disabled[@]} + ${#removed[@]} == 0)) && echo "  None of the known services are running or enabled."
    kept_services=("${kept[@]}")

    echo ""
    echo "--- Software ---"
    local found=0
    for pkg in $(find_candidate_packages); do
        printf '%s\n' "${handled[@]}" | grep -qxF -- "${pkg}" && continue
        pkg_installed "${pkg}" || continue
        # A package that belongs to a service already kept isn't asked about again.
        covered=0
        for name in "${kept_services[@]}"; do
            case "${name}:${pkg}" in
                "${name}:${name}"* | smbd:samba | nmbd:samba | named:bind9 | nfs-server:nfs-kernel-server) covered=1 ;;
            esac
        done
        if ((covered)); then
            mark_kept "${pkg}"
            continue
        fi
        found=1
        echo ""
        echo "  ${pkg}: $(dpkg-query -W -f='${binary:Summary}' "${pkg}" 2>/dev/null)"
        read -r -p "    [k]eep  [r]emove  (Enter = keep): " choice
        if [[ "${choice,,}" == "r" ]]; then
            apt purge "${pkg}" && log "Purged package ${pkg}." && removed+=("${pkg}")
        else
            mark_kept "${pkg}"
            kept+=("${pkg}")
        fi
    done
    ((found)) || echo "  None of the known hacking tools or servers are installed."

    echo ""
    echo "--- Games ---"
    mapfile -t games < <(find_games)
    found=0
    for item in "${games[@]}"; do
        type="${item%%$'\t'*}"
        name="${item#*$'\t'}"
        [[ "${type}" == "apt" ]] && ! pkg_installed "${name}" && continue
        found=1
        echo ""
        echo "  ${name} (${type})"
        read -r -p "    [k]eep  [r]emove  (Enter = keep): " choice
        if [[ "${choice,,}" == "r" ]]; then
            remove_game_item "${type}" "${name}" && removed+=("${name}")
        else
            mark_kept "${name}"
            kept+=("${name}")
        fi
    done
    ((found)) || echo "  No likely games found."

    echo ""
    echo "Kept:     ${kept[*]:-none}"
    echo "Disabled: ${disabled[*]:-none}"
    echo "Removed:  ${removed[*]:-none}"
    if ((${#removed[@]} > 0)) && confirm "Run apt autoremove to clean up leftover dependencies?"; then
        apt autoremove -y
    fi

    echo ""
    if confirm "Show all running services and disable others by name?"; then
        systemctl list-units --type=service --state=running --no-pager --no-legend --plain 2>/dev/null | awk '{print "  " $1}'
        read -r -p "Service names to disable (space separated, Enter = none): " names
        for name in ${names}; do
            [[ "${name}" == *.service ]] || name="${name}.service"
            confirm "Disable and stop ${name}?" && disable_service "${name}"
        done
    fi
}

verify_software_review() {
    local row name desc state pkg item bad=0
    for row in "${SERVICE_CANDIDATES[@]}"; do
        IFS='|' read -r name desc <<< "${row}"
        : "${desc}"
        is_kept "${name}" && continue
        state=$(service_found "${name}.service") && { warn "${name} still ${state}"; bad=1; }
    done
    for pkg in $(find_candidate_packages); do
        is_kept "${pkg}" || { warn "${pkg} still installed"; bad=1; }
    done
    while IFS= read -r item; do
        [[ -z "${item}" ]] && continue
        is_kept "${item#*$'\t'}" || { warn "Possible game: ${item#*$'\t'}"; bad=1; }
    done < <(find_games)
    for row in "${SERVICE_CANDIDATES[@]}"; do
        name="${row%%|*}"
        is_kept "${name}" && service_found "${name}.service" >/dev/null && ! systemctl is-active --quiet "${name}" 2>/dev/null \
            && warn "Kept service ${name} is NOT running"
    done
    ((bad == 0)) && pass "No unreviewed services, tools or games left"
    ((${#KEPT[@]} > 0)) && info "Kept this run: ${!KEPT[*]}"
    return 0
}

disable_service() {
    local unit="$1"
    systemctl disable --now "${unit}" && log "Disabled and stopped ${unit}."
    systemctl list-unit-files "${unit%.service}.socket" --no-legend 2>/dev/null | grep -q . \
        && systemctl disable --now "${unit%.service}.socket" 2>/dev/null
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
        [[ -f "${arg}" ]] && ! pkg_owner "$(readlink -f "${arg}")" >/dev/null && readlink -f "${arg}"
    done
}

is_suspicious() {
    local pid="$1" comm exe
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null)
    [[ "${comm}" =~ ^(python[0-9.]*|perl|ruby[0-9.]*|php[0-9.]*|nc|nc\.traditional|nc\.openbsd|ncat|netcat|socat|bash|sh|dash|node|lua[0-9.]*)$ ]] && return 0
    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
    [[ -n "${exe}" && "${exe}" != /snap/* ]] && ! pkg_owner "${exe}" >/dev/null
}

backdoor_check() {
    header "Backdoor / Listener Check"
    echo "Listening programs. '!!' = script interpreter, netcat, or a program no package installed."
    local -a rows scripts terms
    local i proto port pid cmd mark choice script ref exe base pkg
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
        if is_kept "$(cat "/proc/${pid}/comm" 2>/dev/null)"; then
            echo "  ${cmd} was kept as a required service, skipping."
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
        exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
        base=$(basename "$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | head -1)")
        terms=("${scripts[@]}")
        [[ "${base}" =~ ^(nc|ncat|netcat|socat) ]] && terms+=("${base}")
        # Remove the cron line first, or cron starts the program again a minute later.
        for script in "${terms[@]}"; do
            echo "  Cron lines that start ${script}:"
            review_cron_lines -F "${script}" || echo "    (none)"
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
        if pkg=$(pkg_owner "${exe}") && printf '%s\n' "${PACKAGE_CANDIDATES[@]}" | grep -qxF -- "${pkg}" \
            && ! is_kept "${pkg}" && confirm "Remove the package ${pkg} that provides ${exe}?"; then
            apt purge "${pkg}" && log "Purged package ${pkg}."
        fi
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

# Prints "type<TAB>name" for every likely game found.
find_games() {
    local file pkg regex="^(${GAME_KEYWORDS})"
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
        {
            printf '%s\n' /usr/games/* /usr/local/games/*
            grep -lsE '^Categories=.*Game' /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop \
                /home/*/.local/share/applications/*.desktop /home/*/Desktop/*.desktop
        } | while IFS= read -r file; do
            [[ -e "${file}" ]] || continue
            if pkg=$(pkg_owner "${file}"); then
                echo -e "apt\t${pkg}"
            else
                echo -e "file\t${file}"
            fi
        done
    } | sort -u
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
    for ext in "${MEDIA_EXTS[@]}"; do
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
    echo "File types: ${MEDIA_EXTS[*]}"
    local extra i choice ftp_count
    read -r -p "Extra extensions to search for (space separated, Enter = none): " extra
    for i in ${extra}; do
        MEDIA_EXTS+=("${i#.}")
    done

    local -a files selected=()
    mapfile -d '' files < <(find_media)
    ftp_count=$(find_media ftp | tr -cd '\0' | wc -c)
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

CRON_SUSPICIOUS='(^|[^a-z])(nc|ncat|netcat|nc\.traditional|nc\.openbsd|socat)([^a-z]|$)|/dev/tcp/|(ba)?sh[[:space:]]+-i|-e[[:space:]]*/bin/|(curl|wget)[^|]*\|[[:space:]]*(ba)?sh|python[0-9.]*[[:space:]]+-c|perl[[:space:]]+-e|base64[[:space:]]+(-d|--decode)|[[:space:]]/(tmp|dev/shm|var/tmp)/'

cron_tables() {
    local file
    for file in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
        [[ -f "${file}" && "${file}" != *.bak.* ]] && echo "${file}"
    done
}

# Shows cron lines matching a pattern (grep -E or -F) and offers to remove each one.
# Returns 1 when nothing matched.
review_cron_lines() {
    local flag="$1" pattern="$2" file hit n i backed found=1
    local -a hits
    while IFS= read -r file <&3; do
        mapfile -t hits < <(grep -n "${flag}" -- "${pattern}" "${file}" | grep -vE '^[0-9]+:[[:space:]]*#')
        backed=0
        for ((i = ${#hits[@]} - 1; i >= 0; i--)); do
            hit="${hits[i]}"
            n="${hit%%:*}"
            found=0
            echo "  !! ${file} line ${n}: ${hit#*:}"
            if confirm "     Remove this line?"; then
                if ((backed == 0)); then
                    cp -p "${file}" "${LOG_FILE%/*}/cron_$(basename "${file}")_$(date +%s).bak"
                    backed=1
                fi
                sed -i "${n}d" "${file}" && log "Removed cron line from ${file}: ${hit#*:}"
            fi
        done
    done 3< <(cron_tables)
    return "${found}"
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
    echo "--- Suspicious cron lines (netcat, reverse shells, downloads piped to a shell) ---"
    review_cron_lines -E "${CRON_SUSPICIOUS}" || echo "  None found."
    echo "  A program started by a removed line may still be running: see Backdoor / Listener Check."

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
    if cron_tables | xargs -r -d '\n' grep -hE -- "${CRON_SUSPICIOUS}" 2>/dev/null | grep -qvE '^[[:space:]]*#'; then
        warn "Suspicious cron lines found (run Cron Jobs Review)"
    else
        pass "No suspicious cron lines"
    fi
    users=$(find /var/spool/cron/crontabs -mindepth 1 -maxdepth 1 -printf "%f " 2>/dev/null)
    [[ -n "${users}" ]] && info "User crontabs exist for: ${users}"
    return 0
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

### 7. Auditing & Malware ###

# Login and sudo messages, from the log file or the systemd journal.
auth_log() {
    if [[ -r /var/log/auth.log ]]; then
        cat /var/log/auth.log.1 /var/log/auth.log 2>/dev/null
    else
        journalctl --no-pager -q -o short SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 2>/dev/null
    fi
}

save_report() {
    local file
    file="${LOG_FILE%/*}/cyberpatriot_$1_$(date +%Y%m%d_%H%M%S).txt"
    if confirm "Save this report to ${file}?"; then
        printf '%s\n' "$2" > "${file}" && echo "Saved ${file}."
    fi
}

authorized_key_files() {
    find /root /home -maxdepth 3 -type f -path '*/.ssh/authorized_keys*' -size +0 2>/dev/null
}

last_login_line() {
    local user="$1" line
    if command -v lastlog >/dev/null 2>&1; then
        line=$(lastlog -u "${user}" 2>/dev/null | tail -n +2)
    elif command -v lastlog2 >/dev/null 2>&1; then
        line=$(lastlog2 -u "${user}" 2>/dev/null | tail -n +2)
    else
        line=$(last -n 1 "${user}" 2>/dev/null | head -1)
    fi
    echo "  ${line:-${user}  (no login recorded)}"
}

user_activity_report() {
    local user status changed max file
    echo "== Logged in right now =="
    who 2>/dev/null | sed 's/^/  /' | or_none
    echo ""
    echo "== Last login for each user =="
    for user in root $(human_users); do
        last_login_line "${user}"
    done
    echo ""
    echo "== Most recent logins =="
    last -n 15 2>/dev/null | head -15 | grep . | grep -v '^wtmp begins' | sed 's/^/  /' | or_none
    echo ""
    echo "== Failed logins (count per account) =="
    auth_log | grep -E 'Failed password|authentication failure' \
        | grep -oE '(for (invalid user )?|[[:space:]]user=)[A-Za-z0-9._-]+' | awk '{print $NF}' | sed 's/^user=//' \
        | sort | uniq -c | sort -rn | head -10 | or_none
    echo ""
    echo "== Last failed login attempts =="
    auth_log | grep -E 'Failed password|authentication failure|FAILED LOGIN' | tail -10 | sed 's/^/  /' | or_none
    echo ""
    echo "== Commands run with sudo (last 20) =="
    auth_log | grep -E 'sudo:.*COMMAND=' | tail -20 | sed -E 's/ : .*COMMAND=/ ran: /; s/^/  /' | or_none
    echo ""
    echo "== Account and group changes (last 25) =="
    auth_log | grep -E '(useradd|usermod|userdel|groupadd|groupdel|groupmod|gpasswd|chage|chpasswd|passwd)\[|password changed' \
        | tail -25 | sed 's/^/  /' | or_none
    echo ""
    echo "== When the account files last changed =="
    stat -c '  %.19y  %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers 2>/dev/null
    echo ""
    echo "== Password status =="
    printf "  %-18s %-14s %-12s %s\n" "USER" "STATUS" "LAST CHANGE" "MAX DAYS"
    for user in root $(human_users); do
        read -r _ status changed _ max _ < <(passwd -S "${user}" 2>/dev/null)
        case "${status:-}" in
            P) status="has password" ;;
            L) status="locked" ;;
            NP) status="NO PASSWORD" ;;
        esac
        [[ "${max:-}" == "99999" ]] && max="never expires"
        printf "  %-18s %-14s %-12s %s\n" "${user}" "${status:-?}" "${changed:-?}" "${max:-?}"
    done
    echo ""
    echo "== SSH authorized_keys files (key logins that skip the password) =="
    while IFS= read -r file; do
        printf "  %s  (%s key(s))\n" "${file}" "$(grep -cvE '^[[:space:]]*(#|$)' "${file}")"
    done < <(authorized_key_files) | or_none
}

user_activity_audit() {
    header "User Activity Audit"
    local report file owner
    report=$(user_activity_report 2>&1)
    echo "${report}"
    echo ""
    while IFS= read -r file <&3; do
        owner=$(basename "$(dirname "$(dirname "${file}")")")
        echo "  ${file}:"
        awk '!/^[[:space:]]*(#|$)/ {print "    " $1, $NF}' "${file}"
        if confirm "  Remove ${file}? (only if the README doesn't need SSH key logins)"; then
            cp -p "${file}" "${LOG_FILE%/*}/authorized_keys_${owner}_$(date +%s).bak"
            rm -f -- "${file}" && log "Removed ${file} (backup saved next to the log)."
        fi
    done 3< <(authorized_key_files)
    save_report user_audit "${report}"
}

verify_user_activity() {
    local count never
    count=$(authorized_key_files | grep -c .)
    ((count == 0)) && pass "No SSH authorized_keys files" || warn "${count} authorized_keys file(s) (fine if the README needs key logins)"
    never=$(for u in $(human_users); do passwd -S "$u" 2>/dev/null | awk '$5 == 99999 {printf "%s ", $1}'; done)
    [[ -z "${never}" ]] && pass "All user passwords expire" || warn "Passwords never expire for: ${never}"
}

extra_hosts() {
    grep -vE '^[[:space:]]*(#|$)' /etc/hosts 2>/dev/null \
        | grep -vE '^[[:space:]]*(127\.|::1[[:space:]]|fe00::|ff0[0-9a-f]::)'
}

system_activity_report() {
    local exe file
    echo "== Programs running from unusual folders (/tmp, /var/tmp, /dev/shm, /usr/games) =="
    ps -eo pid=,user=,args= | grep -E '(^|[[:space:]])/(tmp|var/tmp|dev/shm|usr/games)/' | grep -v 'grep -E' \
        | cut -c1-150 | sed 's/^/  /' | or_none
    echo ""
    echo "== Running programs that no package installed =="
    while IFS= read -r exe; do
        [[ "${exe}" == /snap/* ]] && continue
        if [[ "${exe}" == *" (deleted)" ]]; then
            echo "  ${exe}"
        elif [[ -e "${exe}" ]] && ! pkg_owner "${exe}" >/dev/null; then
            echo "  ${exe}"
        fi
    done < <(for file in /proc/[0-9]*; do readlink "${file}/exe" 2>/dev/null; done | sort -u) | or_none
    echo ""
    echo "== Packages installed or removed recently (last 30) =="
    cat /var/log/dpkg.log.1 /var/log/dpkg.log 2>/dev/null | grep -E ' (install|remove|purge) ' | tail -30 \
        | awk '{print "  " $1, $2, $3, $4}' | or_none
    echo ""
    echo "== Files in /etc changed in the last 7 days =="
    find /etc -xdev -type f -mtime -7 ! -name '*.bak.*' -printf '  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null \
        | sort -r | head -40 | or_none
    echo ""
    echo "== Startup services and timers that no package installed =="
    for file in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do
        [[ -f "${file}" && ! -L "${file}" ]] || continue
        pkg_owner "${file}" >/dev/null && continue
        echo "  ${file}"
        grep -E '^(ExecStart|OnCalendar|OnBootSec)=' "${file}" | sed 's/^/      /'
    done | or_none
    echo ""
    echo "== Boot script /etc/rc.local =="
    grep -vE '^[[:space:]]*(#|$)|^exit 0' /etc/rc.local 2>/dev/null | sed 's/^/  /' | or_none
    echo ""
    echo "== Failed services =="
    systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print "  " $1}' | or_none
    echo ""
    echo "== Extra /etc/hosts entries (these can redirect websites) =="
    extra_hosts | sed 's/^/  /' | or_none
}

system_activity_audit() {
    header "System Activity Audit"
    local report
    report=$(system_activity_report 2>&1)
    echo "${report}"
    echo ""
    echo "Nothing was changed. To act on something: Backdoor / Listener Check and Applications &"
    echo "Services Review (menu 5), Cron Jobs Review (menu 6), or edit /etc/hosts by hand."
    save_report system_audit "${report}"
}

verify_system_activity() {
    local count
    count=$(extra_hosts | grep -c .)
    ((count == 0)) && pass "No extra /etc/hosts entries" || warn "${count} extra /etc/hosts entries (check they are meant to be there)"
    count=$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | grep -c .)
    ((count > 0)) && info "${count} failed service(s)"
    return 0
}

AUDIT_RULES="/etc/audit/rules.d/cyberpatriot.rules"
AUDIT_WATCHES=(
    "/etc/passwd|identity" "/etc/shadow|identity" "/etc/group|identity" "/etc/gshadow|identity"
    "/etc/sudoers|sudoers" "/etc/sudoers.d/|sudoers"
    "/etc/ssh/sshd_config|sshd" "/etc/pam.d/|pam" "/etc/login.defs|login-policy"
    "/etc/crontab|cron" "/etc/cron.d/|cron" "/var/spool/cron/|cron"
    "/var/log/lastlog|logins" "/var/log/faillog|logins"
)

audit_logging() {
    header "Audit Logging Setup"
    echo "auditd records who changed important files (accounts, sudo, SSH, PAM, cron)."
    echo "rsyslog writes logins and sudo use to /var/log/auth.log."
    local entry path key
    if ! pkg_installed auditd && confirm "Install auditd?"; then
        apt install -y auditd && log "Installed auditd."
    fi
    if pkg_installed auditd; then
        if confirm "Add watch rules for account, sudo, SSH, PAM and cron files (${AUDIT_RULES})?"; then
            mkdir -p "$(dirname "${AUDIT_RULES}")"
            [[ -f "${AUDIT_RULES}" ]] && backup_file "${AUDIT_RULES}"
            # A rule for a path that doesn't exist stops the rest from loading, so those are skipped.
            for entry in "${AUDIT_WATCHES[@]}"; do
                path="${entry%%|*}"
                key="${entry##*|}"
                [[ -e "${path}" ]] && echo "-w ${path} -p wa -k ${key}"
            done > "${AUDIT_RULES}"
            log "Wrote audit watch rules to ${AUDIT_RULES}."
        fi
        if confirm "Enable and start auditd, and load the rules?"; then
            systemctl enable --now auditd && log "Enabled auditd."
            augenrules --load >/dev/null 2>&1 && log "Loaded audit rules."
            echo "Rules now loaded:"
            auditctl -l 2>/dev/null | sed 's/^/  /' | or_none
        fi
    fi

    echo ""
    if ! pkg_installed rsyslog && confirm "Install rsyslog (text logs such as /var/log/auth.log)?"; then
        apt install -y rsyslog && log "Installed rsyslog."
    fi
    if pkg_installed rsyslog && ! systemctl is-active --quiet rsyslog 2>/dev/null \
        && confirm "rsyslog is not running. Enable and start it?"; then
        systemctl enable --now rsyslog && log "Enabled rsyslog."
    fi

    echo ""
    echo "Reading the audit log later:"
    echo "  ausearch -k identity     changes to passwd / shadow / group"
    echo "  ausearch -k sudoers      changes to sudo rules"
    echo "  aureport -au             login attempts"
}

verify_audit_logging() {
    systemctl is-active --quiet auditd 2>/dev/null && pass "auditd running" || warn "auditd not running"
    [[ -s "${AUDIT_RULES}" ]] && pass "Audit watch rules in place" || warn "No audit watch rules (${AUDIT_RULES})"
    systemctl is-active --quiet rsyslog 2>/dev/null && pass "rsyslog running" || warn "rsyslog not running"
}

antivirus_audit() {
    header "Antivirus / Rootkit Scan"
    if confirm "Install ClamAV and update virus definitions?"; then
        apt install -y clamav clamav-daemon
        systemctl stop clamav-freshclam 2>/dev/null
        freshclam
        systemctl start clamav-freshclam 2>/dev/null
        log "Installed ClamAV and ran freshclam."
    fi
    if command -v clamscan >/dev/null 2>&1 && confirm "Scan /home now (only reports, nothing deleted)?"; then
        clamscan -r -i /home | tee -a "${LOG_FILE}"
    fi
    if confirm "Run a rootkit check with chkrootkit?"; then
        pkg_installed chkrootkit || apt install -y --no-install-recommends chkrootkit
        chkrootkit -q | tee -a "${LOG_FILE}"
    fi
}

verify_antivirus() {
    pkg_installed clamav && info "ClamAV installed" || info "ClamAV not installed (optional)"
}

security_scanners() {
    header "Security Scanners"
    local out
    echo "Lynis checks the whole system and lists warnings and suggestions. It changes nothing."
    if confirm "Run Lynis now (installs the lynis package, takes a few minutes)?"; then
        pkg_installed lynis || apt install -y lynis
        if command -v lynis >/dev/null 2>&1; then
            out="${LOG_FILE%/*}/cyberpatriot_lynis_$(date +%Y%m%d_%H%M%S).txt"
            echo "Running Lynis..."
            lynis audit system --quick --no-colors > "${out}" 2>&1
            echo ""
            echo "Warnings:"
            grep -E '^warning\[\]=' /var/log/lynis-report.dat 2>/dev/null | cut -d= -f2- \
                | awk -F'|' '{print "  [" $1 "] " $2}' | or_none
            echo "Suggestions:"
            grep -E '^suggestion\[\]=' /var/log/lynis-report.dat 2>/dev/null | cut -d= -f2- \
                | awk -F'|' '{print "  [" $1 "] " $2}' | or_none
            echo "Hardening score: $(sed -n 's/^hardening_index=//p' /var/log/lynis-report.dat 2>/dev/null) / 100"
            echo "Full output saved to ${out}"
        else
            echo "Lynis could not be installed."
        fi
    fi

    echo ""
    echo "debsums lists program files that were changed after they were installed (replaced binaries)."
    if confirm "Run debsums now (installs the debsums package)?"; then
        pkg_installed debsums || apt install -y debsums
        if command -v debsums >/dev/null 2>&1; then
            echo "Changed files:"
            debsums -c 2>/dev/null | sed 's/^/  /' | or_none
        else
            echo "debsums could not be installed."
        fi
    fi
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
    header "Decode Text (Base64 / ROT13)"
    local input text decoded
    read -r -p "Encoded text or a file path: " input
    [[ -z "${input}" ]] && return
    if [[ -f "${input}" ]]; then text=$(cat "${input}"); else text="${input}"; fi
    decoded=$(base64 -d <<< "${text}" 2>/dev/null | tr -d '\0')
    echo "Base64 decoded:      ${decoded:-(not valid Base64)}"
    echo "ROT13 decoded:       $(tr 'A-Za-z' 'N-ZA-Mn-za-m' <<< "${text}")"
    [[ -n "${decoded}" ]] && echo "Base64, then ROT13:  $(tr 'A-Za-z' 'N-ZA-Mn-za-m' <<< "${decoded}")"
    return 0
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
    "Software & Services" "Files" "Auditing & Malware" "Forensics Helper (read-only)")
CAT_FUNCS=(
    "user_management group_management password_audit sudoers_audit"
    "password_policy account_lockout login_screen"
    "system_updates"
    "firewall_setup ssh_hardening kernel_hardening ftp_config"
    "software_review backdoor_check"
    "prohibited_media cron_review file_permissions"
    "user_activity_audit system_activity_audit audit_logging antivirus_audit security_scanners"
    "forensic_ports forensic_find forensic_base64 forensic_hash forensic_lookup forensic_recent"
)
declare -A TITLE=(
    [user_management]="User Review" [group_management]="Group Management"
    [password_audit]="Password Audit" [sudoers_audit]="Sudoers Audit"
    [password_policy]="Password Policy" [account_lockout]="Account Lockout"
    [login_screen]="Login Screen (LightDM/GDM)" [system_updates]="System Updates"
    [firewall_setup]="Firewall" [ssh_hardening]="SSH Hardening"
    [kernel_hardening]="Kernel / Network (sysctl)" [ftp_config]="FTP Server (vsftpd)"
    [software_review]="Applications & Services Review" [backdoor_check]="Backdoor / Listener Check"
    [prohibited_media]="Prohibited Media Files" [cron_review]="Cron Jobs Review"
    [file_permissions]="File Permissions" [antivirus_audit]="Antivirus / Rootkit Scan"
    [user_activity_audit]="User Activity Audit" [system_activity_audit]="System Activity Audit"
    [audit_logging]="Audit Logging Setup (auditd / rsyslog)" [security_scanners]="Security Scanners (Lynis / debsums)"
    [forensic_ports]="Listening Ports and Processes" [forensic_find]="Find Files"
    [forensic_base64]="Decode Text (Base64 / ROT13)" [forensic_hash]="File Hashes"
    [forensic_lookup]="User / Group Lookup" [forensic_recent]="Recently Modified Files"
)
declare -A VERIFY_FN=(
    [user_management]=verify_users [group_management]=verify_groups
    [password_audit]=verify_passwords [sudoers_audit]=verify_sudoers
    [password_policy]=verify_policy [account_lockout]=verify_lockout
    [login_screen]=verify_login [system_updates]=verify_updates
    [firewall_setup]=verify_firewall [ssh_hardening]=verify_ssh
    [kernel_hardening]=verify_kernel [ftp_config]=verify_ftp
    [software_review]=verify_software_review [backdoor_check]=verify_backdoor
    [prohibited_media]=verify_media [cron_review]=verify_cron
    [file_permissions]=verify_permissions [antivirus_audit]=verify_antivirus
    [user_activity_audit]=verify_user_activity [system_activity_audit]=verify_system_activity
    [audit_logging]=verify_audit_logging
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
    touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/var/log/cyberpatriot_hardening.log"
    [[ -f "${LOG_FILE}" ]] && SESSION_START=$(wc -l < "${LOG_FILE}")
    trap 'echo ""; change_summary; exit 130' INT
    check_os
    log "=== CyberPatriot hardening script started ==="
    echo ""
    echo "REMINDER: Read the README and answer the forensic questions BEFORE making changes."

    while true; do
        show_main_menu
        read -r -p "Select a category: " choice || break
        case "${choice,,}" in
            0 | q | exit) break ;;
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
