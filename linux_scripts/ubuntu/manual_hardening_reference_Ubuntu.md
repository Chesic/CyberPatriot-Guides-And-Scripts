# Ubuntu / Linux Mint Hardening Reference

Every hardening step, done by hand. Each step says **why** in one line, then
gives commands to copy. Section numbers match the hardening script's menu.

**How to read this sheet**
- `<user>`, `<group>`, `<service>`, `<file>`: replace with the real name (e.g. `<user>` → `jonas`).
- **Decide:** check the README before running the command.
- Editing with nano: **Ctrl+W** search, **Ctrl+O** then **Enter** save, **Ctrl+X** exit.
- Before editing a system file, back it up: `sudo cp <file> <file>.bak`

> **Golden rules**
> 1. **Read the README.** Write down the authorized users, the admins, the
>    critical services and the required software.
> 2. **Answer the Forensics Questions first.** Fixing things can delete the evidence.
> 3. **Never stop or remove a critical service or required program.** That costs points.
> 4. **Keep a second terminal open with `sudo -i`** while editing sudo or PAM
>    files, so a mistake can't lock you out.

## Contents

- [Start Here: Competition Checklist](#start-here-competition-checklist)
- [1. Users and Groups](#1-users-and-groups)
  - [1.1 Users and Admins](#11-users-and-admins)
  - [1.2 Groups](#12-groups)
  - [1.3 Passwords](#13-passwords)
  - [1.4 Sudo Rules](#14-sudo-rules)
- [2. Password and Login Policy](#2-password-and-login-policy)
  - [2.1 Password Ages](#21-password-ages)
  - [2.2 Password Length, History and Blank Passwords](#22-password-length-history-and-blank-passwords)
  - [2.3 Account Lockout](#23-account-lockout)
  - [2.4 Login Screen](#24-login-screen)
- [3. Updates](#3-updates)
- [4. Network and Firewall](#4-network-and-firewall)
  - [4.1 Firewall](#41-firewall)
  - [4.2 SSH](#42-ssh)
  - [4.3 Kernel Settings (sysctl)](#43-kernel-settings-sysctl)
  - [4.4 FTP Server (vsftpd)](#44-ftp-server-vsftpd)
- [5. Software and Services](#5-software-and-services)
  - [5.1 Services](#51-services)
  - [5.2 Prohibited Software](#52-prohibited-software)
  - [5.3 Games](#53-games)
  - [5.4 Backdoors](#54-backdoors)
- [6. Files](#6-files)
  - [6.1 Media Files](#61-media-files)
  - [6.2 Cron Jobs](#62-cron-jobs)
  - [6.3 File Permissions](#63-file-permissions)
- [7. Auditing and Malware](#7-auditing-and-malware)
  - [7.1 User Activity](#71-user-activity)
  - [7.2 System Activity](#72-system-activity)
  - [7.3 Audit Logging (auditd)](#73-audit-logging-auditd)
  - [7.4 Malware and Security Scans](#74-malware-and-security-scans)
- [8. Forensics Tips](#8-forensics-tips)
- [Appendix A: Check Your Work](#appendix-a-check-your-work)
- [Appendix B: What Services and Tools Are](#appendix-b-what-services-and-tools-are)
- [Appendix C: What the Kernel Settings Do](#appendix-c-what-the-kernel-settings-do)

---

## Start Here: Competition Checklist

Work top to bottom. Each step links to its commands.

1. Read the README, answer the Forensics Questions → [8. Forensics](#8-forensics-tips)
2. Start updates in a **second terminal** (they're slow) → [3. Updates](#3-updates)
3. Remove unauthorized users, fix admins, create missing users → [1.1](#11-users-and-admins)
4. Groups the README asks for → [1.2](#12-groups)
5. Weak, blank and README-flagged passwords; lock root → [1.3](#13-passwords)
6. Sudo rules (`NOPASSWD`) → [1.4](#14-sudo-rules)
7. Firewall → [4.1](#41-firewall)
8. Unneeded services, hacking tools, games → [5.1](#51-services) · [5.2](#52-prohibited-software) · [5.3](#53-games)
9. Backdoors and cron jobs → [5.4](#54-backdoors) · [6.2](#62-cron-jobs)
10. Password rules and lockout → [2.1](#21-password-ages) · [2.2](#22-password-length-history-and-blank-passwords) · [2.3](#23-account-lockout)
11. Harden critical services (SSH, FTP) → [4.2](#42-ssh) · [4.4](#44-ftp-server-vsftpd)
12. Kernel settings → [4.3](#43-kernel-settings-sysctl)
13. Media files, file permissions → [6.1](#61-media-files) · [6.3](#63-file-permissions)
14. Login screen → [2.4](#24-login-screen)
15. Auditing and scans → [7. Auditing](#7-auditing-and-malware)
16. Check your work → [Appendix A](#appendix-a-check-your-work)

[↑ Contents](#contents)

---

## 1. Users and Groups

### 1.1 Users and Admins
**Why:** only README users should exist, and only README admins should have `sudo`.

```bash
awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd   # human accounts
getent group sudo adm                                    # who is an admin
```

**Decide** for each account: admin, standard user, or unauthorized.

```bash
sudo adduser <user> sudo            # make admin
sudo adduser <user> adm
sudo deluser <user> sudo            # remove admin rights
sudo deluser <user> adm
sudo deluser --remove-home <user>   # delete an unauthorized user
sudo pkill -KILL -u <user>          # only if delete fails because they're logged in
sudo adduser <user>                 # create a missing user (asks for a password)
sudo passwd -e <user>               # must change password at next login
```

Never delete the account you're logged in as. Keep at least one admin.

**Hidden and misconfigured accounts**

```bash
awk -F: '$3==0 {print $1}' /etc/passwd                  # UID 0: only root should show
cut -d: -f3 /etc/passwd | sort | uniq -d                 # duplicate UIDs (should be empty)
cut -d: -f3 /etc/group  | sort | uniq -d                 # duplicate GIDs (should be empty)
awk -F: '$3>0 && $3<1000 && $7 ~ /sh$/ {print $1, $7}' /etc/passwd   # system accounts with a shell
sudo usermod -s /usr/sbin/nologin <account>              # take that shell away
sudo passwd -l root                                      # lock root (admins use sudo)
```

### 1.2 Groups
**Why:** the README often asks for a group with certain members.

```bash
getent group <group>               # show members
sudo addgroup <group>              # create
sudo adduser <user> <group>        # add a member
sudo deluser <user> <group>        # remove a member
sudo delgroup <group>              # delete
```

### 1.3 Passwords
**Why:** blank, common or short passwords let anyone in.

```bash
sudo passwd -S -a | awk '$2=="NP"'           # accounts with NO password
sudo grep -E '^[^:]+:\$1\$' /etc/shadow      # weak MD5 password hashes
sudo passwd <user>                           # set a new password
sudo passwd -e <user>                        # force a change at next login
sudo passwd -l root                          # lock root instead of giving it a password
```

**Decide:** the README lists each user's password. Change any under 12 characters.
A strong password has 12+ characters with upper, lower, number and symbol, e.g. `Cyb3rPatr!0t$`.

### 1.4 Sudo Rules
**Why:** `NOPASSWD` and `!authenticate` let someone become root without a password.

```bash
sudo grep -rn 'NOPASSWD\|!authenticate' /etc/sudoers /etc/sudoers.d/
sudo visudo                            # edit the main file (checks for mistakes on save)
sudo visudo -f /etc/sudoers.d/<file>   # edit an extra file
sudo visudo -c                         # check everything parses
```

Change `ALL=(ALL) NOPASSWD: ALL` → `ALL=(ALL) ALL`. Delete any `Defaults !authenticate` line.

[↑ Contents](#contents)

---

## 2. Password and Login Policy

### 2.1 Password Ages
**Why:** passwords must expire, and can't be changed back right away.

```bash
sudo nano /etc/login.defs
```
```
PASS_MAX_DAYS   90
PASS_MIN_DAYS   10
PASS_WARN_AGE   7
FAILLOG_ENAB    yes
LOG_UNKFAIL_ENAB yes
SYSLOG_SU_ENAB  yes
SYSLOG_SG_ENAB  yes
```

`login.defs` only affects new accounts. Apply the ages to existing users too:

```bash
sudo chage -M 90 -m 10 -W 7 <user>
sudo chage -l <user>                   # check
```

### 2.2 Password Length, History and Blank Passwords
**Why:** PAM enforces the rules when a password is set or used.

```bash
sudo nano /etc/pam.d/common-password
```

Add `minlen=12 remember=5` to the end of the `pam_unix.so` line:

```
password  [success=1 default=ignore]  pam_unix.so obscure yescrypt minlen=12 remember=5
```

```bash
sudo touch /etc/security/opasswd && sudo chmod 600 /etc/security/opasswd   # stores old passwords
```

**Optional complexity rules** (upper, lower, digit, symbol):

```bash
sudo apt install libpam-pwquality
sudo nano /etc/pam.d/common-password
```

Add to the end of the `pam_pwquality.so` line: `minlen=12 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 difok=3`

**No blank-password logins:**

```bash
sudo nano /etc/pam.d/common-auth
```

On the `pam_unix.so` line, delete the word `nullok`.

### 2.3 Account Lockout
**Why:** locks an account after repeated wrong passwords (stops brute force).

Create three files with `sudo nano <file>`:

`/usr/share/pam-configs/faillock`
```
Name: Lockout on failed logins
Default: no
Priority: 0
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail
```

`/usr/share/pam-configs/faillock_reset`
```
Name: Reset lockout on success
Default: no
Priority: 0
Auth-Type: Additional
Auth:
	required	pam_faillock.so authsucc
```

`/usr/share/pam-configs/faillock_notify`
```
Name: Notify on account lockout
Default: no
Priority: 1024
Auth-Type: Primary
Auth:
	requisite	pam_faillock.so preauth
```

Turn them on and set limits:

```bash
sudo pam-auth-update --enable faillock faillock_reset faillock_notify
sudo nano /etc/security/faillock.conf        # set: deny = 5   and   unlock_time = 900
grep faillock /etc/pam.d/common-auth         # check: 3 lines
sudo faillock --user <user> --reset          # unlock someone
```

### 2.4 Login Screen
**Why:** no guest account, no auto-login, no list of valid usernames.

**LightDM** (Linux Mint): `sudo nano /etc/lightdm/lightdm.conf`, under `[Seat:*]`:
```
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=true
autologin-user=none
```

**GDM** (Ubuntu): `sudo nano /etc/gdm3/custom.conf`, under `[daemon]`:
```
AutomaticLoginEnable=false
TimedLoginEnable=false
```
Then `sudo nano /etc/gdm3/greeter.dconf-defaults`, under `[org/gnome/login-screen]`:
```
disable-user-list=true
disable-restart-buttons=true
```
```bash
sudo dconf update
```

Reboot to apply.

[↑ Contents](#contents)

---

## 3. Updates

**Why:** updates fix known security holes. Start them early: they're slow.

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install --only-upgrade <package>   # one program, e.g. firefox, chromium, openssh-server, systemd
sudo snap refresh                           # snap apps (Ubuntu's Firefox is a snap)
```

If apt asks about a changed config file, keeping the local version is usually safest.

**Automatic updates**

```bash
sudo apt install unattended-upgrades
sudo nano /etc/apt/apt.conf.d/20auto-upgrades
```
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

- **Linux Mint:** `sudo mintupdate-automation upgrade enable`, or Update Manager → Edit → Preferences → Automation.
- **Ubuntu:** Software & Updates → Updates → check *Daily*, security updates *Download and install automatically*.
- **apt errors about sources:** Mint: open Update Manager and accept its offer to fix the sources / switch mirror. Ubuntu: Software & Updates → Ubuntu Software → *Download from: Main server*.

[↑ Contents](#contents)

---

## 4. Network and Firewall

### 4.1 Firewall
**Why:** blocks every incoming connection you didn't allow.

```bash
sudo apt install ufw                # if missing
sudo ufw allow ssh                  # Decide: only if SSH is a critical service
sudo ufw allow ftp                  # Decide: only if FTP is a critical service
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

Mint GUI: Control Center → Firewall Configuration → Status on.

### 4.2 SSH
**Why:** SSH faces the network, so weak settings let attackers in.

**Decide:** is SSH (`openssh-server`) a critical service in the README?

Not needed:
```bash
sudo systemctl disable --now ssh
sudo apt purge openssh-server
```

Needed: `sudo nano /etc/ssh/sshd_config`. Remove any `#` in front and set:
```
PermitRootLogin no
PermitEmptyPasswords no
LoginGraceTime 60
MaxAuthTries 4
X11Forwarding no
IgnoreRhosts yes
HostbasedAuthentication no
PermitUserEnvironment no
UsePAM yes
PasswordAuthentication yes
```

The **first** value sshd reads wins, and files in `/etc/ssh/sshd_config.d/` are read first.
Find every copy of a setting (any upper/lower case) and fix them all:

```bash
sudo grep -rin 'permitrootlogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
sudo sshd -t                                   # check for mistakes (no output = OK)
sudo systemctl restart ssh
sudo sshd -T | grep -i permitrootlogin         # the value really in effect
```

### 4.3 Kernel Settings (sysctl)
**Why:** turns on memory and network protections. What each does: [Appendix C](#appendix-c-what-the-kernel-settings-do).

```bash
sudo nano /etc/sysctl.conf
```

Change existing lines or add them at the bottom:
```
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
kernel.randomize_va_space = 2
```

**Decide:** only if the README doesn't need IPv6, also add:
```
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
```

Bad values can be planted in other files too. Find and fix them, then apply:

```bash
sudo grep -rn 'randomize_va_space\|syncookies\|ip_forward' /etc/sysctl.conf /etc/sysctl.d/
sudo sysctl --system
sysctl kernel.randomize_va_space net.ipv4.tcp_syncookies net.ipv4.ip_forward   # check
```

### 4.4 FTP Server (vsftpd)
**Why:** FTP sends passwords as plain text.

**Decide:** is FTP critical in the README?
- **Not needed:** `sudo systemctl disable --now vsftpd` and `sudo apt purge vsftpd`
- **Needed:** configure it, never stop it, and don't delete the files it shares (`/srv/ftp`, `/var/ftp`).

```bash
sudo nano /etc/vsftpd.conf
```

Anonymous logins only:
```
anonymous_enable=YES
local_enable=NO
anon_root=/var/ftp
anon_upload_enable=NO
anon_mkdir_write_enable=NO
```

Real users only:
```
anonymous_enable=NO
local_enable=YES
chroot_local_user=YES
```

```bash
sudo systemctl restart vsftpd
systemctl status vsftpd                  # must say active (running)
```

[↑ Contents](#contents)

---

## 5. Software and Services

### 5.1 Services
**Why:** every running service is something to attack. What each one does: [Appendix B](#appendix-b-what-services-and-tools-are).

```bash
systemctl list-units --type=service --state=running   # what's running
sudo ss -tulnp                                         # what's listening on the network
```

**Decide** for each: keep (critical), disable, or remove.

```bash
sudo systemctl disable --now <service>                 # stop now and at boot
dpkg -S /lib/systemd/system/<service>.service          # which package installed it
sudo apt purge <package>                               # uninstall it
```

### 5.2 Prohibited Software
**Why:** hacking tools and unneeded servers are scored as prohibited. Desktop icons show what's installed.

```bash
apt list --installed 2>/dev/null | grep -E 'john|hydra|nmap|zenmap|wireshark|tshark|ophcrack|aircrack|ettercap|kismet|nikto|sqlmap|medusa|hashcat|fcrackzip|doona|xprobe|netcat|ncat|deluge|transmission|qbittorrent'
sudo apt purge <package>             # e.g. sudo apt purge 'wireshark*'
sudo apt autoremove
```

**Decide:** some images require a tool (e.g. Wireshark). `netcat-openbsd` is part of normal Ubuntu.

### 5.3 Games
**Why:** games are non-work software the README forbids.

```bash
dpkg-query -W -f='${Section} ${Package}\n' | grep games    # game packages
ls /usr/games /usr/local/games                             # game programs and loose files
grep -l 'Categories=.*Game' /usr/share/applications/*.desktop
snap list
flatpak list
```
```bash
sudo apt purge <game>            # e.g. aisleriot gnome-mines zangband
sudo snap remove <game>
sudo flatpak uninstall <app-id>
sudo rm '<file>'                 # loose files, e.g. a zip in /usr/games
```

### 5.4 Backdoors
**Why:** a hidden program listening on a port lets attackers in.

**Find it:**
```bash
sudo ss -tlnp                         # odd ports (1337, 4444, 31337) or python/perl/nc programs
ps -ef | grep -E 'python|perl|nc|ncat|socat'
sudo ls -l /proc/<pid>/exe            # the real program file
dpkg -S <file>                        # "no path found" = not from a package
```

**Answer any Forensics Question about it first** (e.g. its folder), then remove it **in this order**:

```bash
sudo crontab -l                                          # 1. find what restarts it ...
sudo grep -rln '<name>' /etc/cron* /var/spool/cron /etc/systemd/system /etc/rc.local
sudo crontab -e                                          #    ... and delete that line
sudo systemctl disable --now <unit>                      #    (if a systemd unit starts it)
sudo pkill -f <name>                                     # 2. stop it
sudo rm <script>                                         # 3. delete the script
sudo apt purge <package>                                 # 4. remove the tool, e.g. netcat-traditional
```

[↑ Contents](#contents)

---

## 6. Files

### 6.1 Media Files
**Why:** the README usually bans non-work media (music, video).

```bash
sudo updatedb
locate -i '*.mp3'                     # repeat for: mp4 ogg wav flac avi mkv mov m4a wma aac webm mpg
sudo find /home /root /tmp /srv /opt /media /mnt -type f \( -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.mov' \) -not -path '*/ftp/*'
sudo rm '<file>'
```

**Don't delete:** files in FTP shares (`/srv/ftp`, `/var/ftp`) or system sounds under `/usr`.

### 6.2 Cron Jobs
**Why:** attackers use cron to restart backdoors every minute.

```bash
cat /etc/crontab
ls /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
sudo ls /var/spool/cron/crontabs                 # users with their own crontab
sudo crontab -l -u <user>                        # show (root: sudo crontab -l)
sudo crontab -e -u <user>                        # edit: delete just the bad line
cat /etc/rc.local                                # runs at boot
```

**Red flags:** `nc`, `ncat`, `netcat`, `socat`, `bash -i`, `/dev/tcp/`, `curl … | sh`, `wget … | sh`, `python -c`, `base64 -d`, scripts in `/tmp` or `/dev/shm`.

### 6.3 File Permissions
**Why:** password hashes and sudo rules must not be readable or writable by everyone.

| File | Should be | Fix |
|---|---|---|
| `/etc/passwd`, `/etc/group` | `644 root:root` | `sudo chmod 644 <file>` |
| `/etc/shadow`, `/etc/gshadow` | `640 root:shadow` | `sudo chmod 640 <file> && sudo chown root:shadow <file>` |
| `/etc/sudoers` | `440 root:root` | `sudo chmod 440 /etc/sudoers` |

```bash
stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/sudoers
sudo find /etc -type f -perm -0002                                   # world-writable (should be none)
sudo find / -xdev -type f -perm -4000 2>/dev/null | grep -vE '^/(usr/)?(s?bin|lib)'   # odd SUID programs
```

[↑ Contents](#contents)

---

## 7. Auditing and Malware

### 7.1 User Activity
**Why:** shows who logged in, failed, used sudo, or changed accounts.

```bash
who                                       # logged in now
last                                      # recent logins
lastlog                                   # last login of every account
sudo lastb                                # failed logins
sudo passwd -S -a                         # password status: P set, L locked, NP none
sudo grep 'Failed password' /var/log/auth.log
sudo grep 'COMMAND=' /var/log/auth.log    # every sudo command
sudo grep -E 'useradd|usermod|userdel|groupadd|passwd' /var/log/auth.log
ls -l /etc/passwd /etc/shadow /etc/group /etc/sudoers   # when they last changed
```

No `/var/log/auth.log`? Use `sudo journalctl | grep sudo`, or install it: `sudo apt install rsyslog`.

**SSH keys** log in without a password. A planted key is a back door:

```bash
sudo ls -la /root/.ssh /home/*/.ssh
sudo cat /home/<user>/.ssh/authorized_keys
sudo rm /home/<user>/.ssh/authorized_keys         # Decide: only if the README doesn't need key logins
```

### 7.2 System Activity
**Why:** spots planted programs, packages, startup services and redirected websites.

```bash
ps aux | grep -E '/tmp|/dev/shm|/usr/games'      # programs running from odd folders
grep -E ' install | remove ' /var/log/dpkg.log   # recent package changes
sudo find /etc -type f -mtime -7                  # /etc files changed in 7 days
ls -l /etc/systemd/system                         # extra startup services
systemctl --failed                                # broken services
cat /etc/hosts                                    # should only be localhost lines + this PC's name
```

### 7.3 Audit Logging (auditd)
**Why:** records who changes account, sudo, SSH, PAM and cron files from now on.

```bash
sudo apt install auditd
sudo nano /etc/audit/rules.d/hardening.rules
```
```
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/pam.d/ -p wa -k pam
-w /etc/login.defs -p wa -k login-policy
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
-w /var/log/lastlog -p wa -k logins
-w /var/log/faillog -p wa -k logins
```
```bash
sudo systemctl enable --now auditd
sudo augenrules --load
sudo auditctl -l                  # rules loaded
sudo ausearch -k identity         # who changed the account files
sudo aureport -au                 # login report
sudo apt install rsyslog && sudo systemctl enable --now rsyslog   # text logs (auth.log)
```

### 7.4 Malware and Security Scans

| Tool | Finds |
|---|---|
| ClamAV | Viruses |
| chkrootkit | Rootkits (malware that hides itself) |
| Lynis | Weak settings across the whole system |
| debsums | Program files changed after install (replaced binaries) |

```bash
sudo apt install clamav && sudo systemctl stop clamav-freshclam && sudo freshclam
sudo clamscan -r -i /home
sudo apt install chkrootkit && sudo chkrootkit
sudo apt install lynis && sudo lynis audit system      # read Warnings and Suggestions at the end
sudo apt install debsums && sudo debsums -c             # no output = nothing changed
```

[↑ Contents](#contents)

---

## 8. Forensics Tips

| Task | Command |
|---|---|
| Program listening on a port | `sudo ss -tlnp` |
| Full command line of a process | `ps -ef \| grep <name>` |
| Find a file | `sudo updatedb && locate <name>` |
| Decode Base64 | `echo '<text>' \| base64 -d` |
| Decode ROT13 | `echo '<text>' \| tr 'A-Za-z' 'N-ZA-Mn-za-m'` |
| Hash a file | `md5sum <file>` · `sha256sum <file>` |
| User's groups and details | `id <user>` · `sudo chage -l <user>` |
| Group members | `getent group <group>` |
| Recently changed files | `find /home -type f -mtime -7` |
| Read a network capture | `tshark -r <file.pcap>` |
| Follow a TCP stream | `tshark -q -z follow,tcp,ascii,<n> -r <file.pcap>` |
| Extract data hidden in an image | `steghide extract -sf <image> -p <passphrase>` |

Type the answer in the Forensics Question file and **save** it.

[↑ Contents](#contents)

---

## Appendix A: Check Your Work

```bash
getent group sudo                                        # admins match the README
sudo passwd -S -a | awk '$2=="NP"'                       # empty = no blank passwords
grep -E '^PASS_(MAX|MIN|WARN)' /etc/login.defs
grep pam_unix /etc/pam.d/common-password                 # minlen=12 remember=5
grep -c nullok /etc/pam.d/common-auth                    # 0
grep -c faillock /etc/pam.d/common-auth                  # 3
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/      # nothing
sudo ufw status                                          # active
sudo sshd -T | grep -Ei '^(permitrootlogin|permitemptypasswords|x11forwarding) '
sysctl kernel.randomize_va_space net.ipv4.tcp_syncookies net.ipv4.ip_forward net.ipv4.tcp_rfc1337
apt list --upgradable                                    # empty
cat /etc/apt/apt.conf.d/20auto-upgrades
stat -c '%a %n' /etc/shadow /etc/passwd /etc/sudoers     # 640 644 440
systemctl is-active <critical-service>                   # active, for every README service
```

[↑ Contents](#contents)

---

## Appendix B: What Services and Tools Are

**Services**

| Service | What it does | Usually |
|---|---|---|
| `nginx`, `apache2` | Web server | Remove unless the README needs a website |
| `squid` | Web proxy | Remove |
| `dovecot` | Email mailbox server (POP3/IMAP) | Remove |
| `postfix`, `sendmail`, `exim4` | Email sending server | Remove |
| `smbd`, `nmbd` (Samba) | Windows-style file sharing | Remove unless required |
| `vsftpd`, `pure-ftpd`, `proftpd` | FTP server | **Check README**, often critical |
| `tftpd-hpa`, `atftpd` | File transfer with no password | Remove |
| `telnet`, `inetd`, `xinetd` | Unencrypted remote login | Remove |
| `ssh` | Encrypted remote login | **Check README**, often critical |
| `snmpd` | Network monitoring, leaks system info | Remove |
| `nfs-server`, `rpcbind` | Unix file sharing | Remove unless required |
| `bind9` / `named` | DNS server | Remove unless required |
| `x11vnc`, `vncserver` | Remote desktop | Remove |
| `mysql`, `mariadb`, `postgresql` | Database | Keep only if required |
| `openvpn` | VPN tunnel | Remove unless required |
| `rsync` | File sync daemon | Remove unless required |
| `cups` | Printing | Usually fine |
| `avahi-daemon` | Announces the PC on the network | Can disable |

**Tools**

| Package | What it is |
|---|---|
| `john`, `hashcat`, `ophcrack`, `fcrackzip` | Password crackers |
| `hydra`, `medusa` | Brute-force login attackers |
| `doona` | Fuzzer (sends junk to crash programs) |
| `nmap`, `zenmap`, `xprobe` | Network and port scanners |
| `wireshark`, `tshark` | Network traffic capture |
| `netcat`, `ncat`, `socat` | Raw network connections, common backdoor |
| `aircrack-ng`, `kismet` | Wi-Fi cracking |
| `ettercap` | Man-in-the-middle attacks |
| `nikto`, `sqlmap` | Website attack tools |
| `deluge`, `transmission`, `qbittorrent` | BitTorrent clients |

[↑ Contents](#contents)

---

## Appendix C: What the Kernel Settings Do

| Setting | Effect |
|---|---|
| `kernel.randomize_va_space = 2` | **ASLR**: random memory layout, makes exploits harder |
| `net.ipv4.tcp_syncookies = 1` | **SYN cookies**: survive SYN-flood attacks |
| `net.ipv4.tcp_rfc1337 = 1` | Ignore fake "reset" packets (TIME-WAIT assassination) |
| `net.ipv4.ip_forward = 0` | Don't act as a router |
| `*.accept_redirects = 0`, `secure_redirects = 0` | Ignore messages that reroute your traffic |
| `*.send_redirects = 0` | Don't send reroute messages |
| `*.rp_filter = 1` | Drop packets with faked source addresses |
| `accept_source_route = 0` | Ignore packets that pick their own route |
| `log_martians = 1` | Log packets with impossible addresses |
| `icmp_echo_ignore_broadcasts = 1` | Ignore broadcast pings (Smurf attack) |
| `tcp_max_syn_backlog`, `tcp_synack_retries`, `tcp_syn_retries` | More SYN-flood resistance |
| `net.ipv6.conf.*.disable_ipv6 = 1` | Turn off IPv6 (only if not needed) |

[↑ Contents](#contents)
