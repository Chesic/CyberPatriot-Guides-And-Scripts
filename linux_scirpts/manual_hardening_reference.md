# Linux Hardening Reference

This sheet follows the same layout as the menu in `cyberPatriot_Script.sh`.
For every item it explains **what the setting or program does**, **why it
matters**, and the **commands to do it by hand**. The goal is to understand
the change, not just run it.

Run commands as root or with `sudo`. Words in `<angle brackets>` are
placeholders you replace.

> **Before changing anything:** read the README and answer the Forensics
> Questions first. Fixing the system can destroy the evidence a question asks
> about (for example, deleting a backdoor before you've recorded its folder).

---

## How the script is organized

```
Main menu
 1) Users & Groups            User Management, Group Management, Password Audit, Sudoers Audit
 2) Password & Login Policy   Password Policy, Account Lockout, Login Screen
 3) Updates                   System Updates
 4) Network & Firewall        Firewall, SSH Hardening, Kernel/sysctl, FTP Server (vsftpd)
 5) Software & Services       Services, Backdoor/Listener Check, Prohibited Software, Game Software
 6) Files                     Prohibited Media, Cron Jobs Review, File Permissions
 7) Malware & Auditing        Antivirus / Auditing
 8) Forensics Helper          read-only lookups for forensics questions
 S) README setup   L) Edit lists   V) Verify all   0) Exit
```

- **Choosing:** type a category number, then one or more function numbers
  (`1`, `1 3`, `2-4`). `a` runs the whole category and `b` goes back.
- **Confirming:** every change asks `[y/N]`. Pressing Enter means **No**.
- **Checking:** after a function runs, a check prints `[PASS]` / `[WARN]` for
  what it covers. `V` runs every check.
- **Exit summary:** when you exit, the script lists every change it made this
  run. The full log is in `cyberpatriot_hardening.log`.
- **Backups:** before a config file is edited, the script copies it to
  `<file>.bak.<timestamp>`. To undo a change, copy that file back.

### README setup and editable lists

`cyberpatriot_lists.conf` (next to the script) is a plain-text file of lists,
one entry per line under a `[section]`. Edit it in any text editor, or use
`L) Edit lists` in the menu.

| List | What it's for |
|---|---|
| `critical_services` | Services the README says must keep running (e.g. `vsftpd`, `openssh-server`). **Never offered for removal or disabling.** |
| `required_software` | Programs the README says to keep. Also protected. |
| `authorized_admins` / `authorized_users` | Names from the README. User Management compares every account against these. |
| `prohibited_services` | Services the Services function offers to disable. |
| `prohibited_software` | Packages the Prohibited Software function offers to remove. |
| `game_keywords` | Name patterns used to spot games. |
| `media_types` | File extensions the media scan looks for. |

`S) README setup` fills in the first four lists. It's offered at startup.
Entering critical services first matters: in the Mint 21 practice round,
stopping vsftpd cost **-5 points** because the README listed it as critical.

---

## 1. Users & Groups

### User Management
**What it is:** every person who can log in has an account. Accounts in the
`sudo` group (and `adm`) are **administrators**: they can run any command as
root.

**Why it matters:** each extra account is another password an attacker can
guess. Each extra admin is another way to take over the whole machine. The
README lists exactly who should exist and who should be an admin; everyone
else should be removed or have admin rights taken away.

The script shows each user with a "README SAYS" column and suggests keep,
admin, standard or delete. Deleting always asks a second time.

```bash
# List accounts with UID and login shell (real users have UID 1000+)
awk -F: '$3 >= 1000 {print $1, $3, $7}' /etc/passwd

# Who is in the admin groups?
getent group sudo adm

# Remove a user and their home folder (unauthorized user)
deluser --remove-home <user>          # or: userdel -r <user>

# Take away admin rights
gpasswd -d <user> sudo
gpasswd -d <user> adm

# Give admin rights
usermod -aG sudo,adm <user>

# Create a missing user and set a password
adduser <user>                        # or: useradd -m -s /bin/bash <user>; passwd <user>

# Only root should have UID 0 (UID 0 = full root powers)
awk -F: '$3 == 0 {print $1}' /etc/passwd

# Lock the root account so nobody can log in as root directly
passwd -l root
```

**System accounts** (UID below 1000, like `www-data` or `ftp`) run services
and should never have a login shell like `/bin/bash`. Set theirs to
`/usr/sbin/nologin` with `usermod -s /usr/sbin/nologin <user>`.

### Group Management
**What it is:** a group is a named set of users. Permissions can be given to
a group instead of to each person.

**Why it matters:** READMEs often ask you to create a group and add specific
people to it (e.g. "create group `marketing` with tessa, gideon, elsie,
delaney").

```bash
addgroup <group>                      # or: groupadd <group>
gpasswd -a <user> <group>             # add one user
gpasswd -M user1,user2,user3 <group>  # set the full member list
gpasswd -d <user> <group>             # remove a user
getent group <group>                  # show members
```

### Password Audit
**What it does:** the script checks each password's hash in `/etc/shadow`
(the file holding scrambled passwords). It flags passwords that are empty,
use an old weak hash type (MD5 or DES), match a common guess (`password`,
`123456`, the username plus `123`, and so on), or are older than the maximum
age. **Passwords that pass are left alone.**

**Why it matters:** an empty or common password lets anyone log in. A blank
root password is a classic scored item.

```bash
getent shadow <user>       # 2nd field: empty = no password, starts with ! = locked
passwd -S <user>           # P = has password, L = locked, NP = no password
passwd <user>              # set a new password
passwd -l root             # lock root instead of giving it a password
```

### Sudoers Audit
**What it is:** `/etc/sudoers` and the files in `/etc/sudoers.d/` decide who
may use `sudo`.

**Why it matters:**
- `NOPASSWD` lets someone run commands as root **without typing a password**.
- `!authenticate` turns password checks off entirely.

Both are common planted vulnerabilities.

```bash
grep -rn 'NOPASSWD\|!authenticate' /etc/sudoers /etc/sudoers.d/
visudo                        # always edit with visudo: it checks syntax before saving
visudo -f /etc/sudoers.d/<file>
```

A broken sudoers file can lock everyone out of `sudo`, so the script checks
with `visudo -c` and restores the backup if the check fails.

---

## 2. Password & Login Policy

### Password Policy
**`/etc/login.defs`** sets defaults for **new** accounts:

| Setting | Meaning |
|---|---|
| `PASS_MAX_DAYS 90` | Password must be changed at least every 90 days |
| `PASS_MIN_DAYS 10` | Can't change it again for 10 days, which stops people from instantly cycling back to an old one |
| `PASS_WARN_AGE 7` | Warn 7 days before it expires |
| `FAILLOG_ENAB`, `LOG_UNKFAIL_ENAB` | Log failed logins |
| `SYSLOG_SU_ENAB`, `SYSLOG_SG_ENAB` | Log use of `su` / `sg` |

Existing accounts keep their old settings, so apply ages to them with
`chage`. The practice round scored "User briar has a maximum password age".

```bash
chage -M 90 -m 10 -W 7 <user>
chage -l <user>               # show a user's settings
```

**PAM** (Pluggable Authentication Modules) is the system Linux uses to check
passwords. Its rules live in `/etc/pam.d/`.

| File / option | What it does |
|---|---|
| `common-password` → on the `pam_unix.so` line, add `minlen=10` | Passwords must be at least 10 characters |
| `common-password` → same line, add `remember=5` | Can't reuse any of the last 5 passwords (stored in `/etc/security/opasswd`) |
| `common-auth` → remove `nullok` | `nullok` lets accounts with an **empty** password log in; removing it blocks that |
| `pam_pwquality.so ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1` | Require at least one uppercase, lowercase, digit and symbol (package `libpam-pwquality`) |

Example line after editing:

```
password  [success=1 default=ignore]  pam_unix.so obscure yescrypt minlen=10 remember=5
```

### Account Lockout
**What it is:** `pam_faillock` counts failed logins and locks the account
after too many.

**Why it matters:** it stops brute-force attacks, where a program tries
thousands of passwords. The script creates the three profiles below and
turns them on with `pam-auth-update`; your earlier PAM edits are kept.

```bash
# /usr/share/pam-configs/faillock
Name: Lockout on failed logins
Default: no
Priority: 0
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail

# /usr/share/pam-configs/faillock_reset
Name: Reset lockout on success
Default: no
Priority: 0
Auth-Type: Additional
Auth:
	required	pam_faillock.so authsucc

# /usr/share/pam-configs/faillock_notify
Name: Notify on account lockout
Default: no
Priority: 1024
Auth-Type: Primary
Auth:
	requisite	pam_faillock.so preauth
```

```bash
pam-auth-update --enable faillock faillock_reset faillock_notify   # or run it and tick the three
# Optional limits in /etc/security/faillock.conf:
#   deny = 5          lock after 5 failures
#   unlock_time = 900 unlock after 15 minutes
faillock --user <user>          # see failures; add --reset to unlock
```

### Login Screen
**What it is:**
- **LightDM** is the login screen on Linux Mint and Xubuntu.
- **GDM** is the login screen on Ubuntu with GNOME.

| Setting | Why |
|---|---|
| `allow-guest=false` | The guest account needs no password, so anyone could use the machine |
| `greeter-hide-users=true` / `disable-user-list=true` | Don't show valid usernames on the login screen; an attacker would have to guess them too |
| `greeter-show-manual-login=true` | Let users type their username |
| `autologin-user=none` / `AutomaticLoginEnable=false` | Nobody gets logged in without a password |

Files: `/etc/lightdm/lightdm.conf` (under `[Seat:*]`),
`/etc/gdm3/custom.conf` (under `[daemon]`), and
`/etc/gdm3/greeter.dconf-defaults`. Reboot to apply. Restarting the display
manager logs you out.

---

## 3. Updates

**Why it matters:** updates fix known security holes. Attackers use public
lists of these holes against unpatched machines. The practice round scored
"vsftpd updated".

```bash
apt update                      # refresh the list of available versions
apt list --upgradable           # see what's outdated
apt full-upgrade -y             # upgrade everything (may add/remove packages)
apt install --only-upgrade <package>   # update one program, e.g. firefox
```

- **Main browser:** the script asks which browser is the main one (Firefox,
  Chromium, Chrome…) and updates it, then asks about the others.
- **Automatic updates:**
  - Ubuntu uses `unattended-upgrades`, controlled by
    `/etc/apt/apt.conf.d/20auto-upgrades`.
  - Linux Mint uses Update Manager → Edit → Preferences → Automation, or
    `mintupdate-automation upgrade enable`.
- **Config file prompts:** during upgrades, apt may ask whether to keep your
  config file or install the maintainer's version. Keeping yours is usually
  safer, but read the question.

---

## 4. Network & Firewall

### Firewall (UFW)
**What it is:** a firewall decides which network connections are allowed in
and out. **UFW** ("Uncomplicated Firewall") is the simple front end used on
Ubuntu and Mint. **firewalld** is used on some other distributions.

**Why it matters:**
- "Deny incoming" means only services you explicitly allow can be reached
  from the network.
- Before enabling it, allow the ports that critical services need, or you'll
  cut them off:

  | Port | Service |
  |---|---|
  | 21 | FTP |
  | 22 | SSH |
  | 80 / 443 | Web |

```bash
ufw status verbose
ufw allow OpenSSH            # or: ufw allow 22/tcp
ufw allow 21/tcp             # FTP, if it's a critical service
ufw default deny incoming
ufw default allow outgoing
ufw enable
```

### SSH Hardening
**What it is:** **SSH** (OpenSSH, package `openssh-server`) lets people log
in and run commands remotely.

**Why it matters:** an SSH server faces the network, so weak settings can let
an attacker in. If the README doesn't require SSH, removing it is safest. If
it does, harden `/etc/ssh/sshd_config`:

| Setting | Why |
|---|---|
| `PermitRootLogin no` | Attackers always try `root` first; make them use a normal account and `sudo` |
| `PermitEmptyPasswords no` | No logging in with a blank password |
| `LoginGraceTime 60` | Drop connections that don't log in within 60 seconds |
| `X11Forwarding no` | Don't tunnel graphical apps; that's extra attack surface |
| `UsePAM yes` | Use the system password and lockout rules above |
| `Protocol 2` | Old SSH protocol 1 is broken (modern OpenSSH only does 2 anyway) |

```bash
sshd -t                      # test the config for errors BEFORE restarting
systemctl restart ssh
sshd -T | grep -i permitrootlogin   # show the setting actually in effect
```

Files in `/etc/ssh/sshd_config.d/` override the main file.

### Kernel / Network Hardening (sysctl)
**What it is:** `sysctl` settings change how the Linux kernel behaves.

**Why it matters:** `/etc/sysctl.conf` is applied **last** by
`sysctl --system`, so values there override everything else. Practice images
often plant bad values in this file (e.g. `kernel.randomize_va_space=0`), so
the script edits it directly.

| Setting | What it does |
|---|---|
| `kernel.randomize_va_space = 2` | **ASLR**: loads programs at random memory addresses, making buffer-overflow exploits much harder |
| `net.ipv4.tcp_syncookies = 1` | **SYN cookies**: defends against SYN floods, a denial-of-service attack that fills the connection table |
| `net.ipv4.tcp_rfc1337 = 1` | **TIME-WAIT assassination protection**: ignore fake reset packets that try to kill connections |
| `net.ipv4.ip_forward = 0` | Don't act as a router passing traffic between networks |
| `net.ipv4.conf.*.accept_redirects = 0`, `secure_redirects = 0` | Ignore ICMP "redirect" messages that could reroute your traffic through an attacker |
| `net.ipv4.conf.*.send_redirects = 0` | Don't send redirects (only routers should) |
| `net.ipv4.conf.*.rp_filter = 1` | Drop packets with spoofed (faked) source addresses |
| `net.ipv4.conf.all.accept_source_route = 0` | Ignore packets that dictate their own route |
| `net.ipv4.conf.all.log_martians = 1` | Log packets with impossible addresses |
| `net.ipv4.icmp_echo_ignore_broadcasts = 1` | Ignore broadcast pings (Smurf attacks) |
| `net.ipv4.tcp_max_syn_backlog = 2048`, `tcp_synack_retries = 2`, `tcp_syn_retries = 5` | More SYN-flood resilience |
| `net.ipv6.conf.*.disable_ipv6 = 1` | Turn off IPv6, **only** if nothing needs it |

```bash
sysctl -n kernel.randomize_va_space     # show the current value
sysctl -w net.ipv4.tcp_rfc1337=1        # change now (lost at reboot)
# put "key = value" lines in /etc/sysctl.conf to make them permanent, then:
sysctl --system
```

### FTP Server (vsftpd)
**What it is:** **FTP** (File Transfer Protocol) shares files over the
network. **vsftpd** is the usual FTP server. FTP sends passwords in plain
text, which is why the practice round's forensics question could read
passwords from a packet capture.

**Why it matters:** when the README makes FTP a **critical service**, don't
remove it. Configure it the way the README asks. Main settings in
`/etc/vsftpd.conf`:

| Setting | Meaning |
|---|---|
| `anonymous_enable=YES/NO` | Allow logging in as "anonymous" with no real account |
| `local_enable=YES/NO` | Allow real system users to log in. Turning it off means real passwords are never sent over FTP |
| `anon_root=/var/ftp` | Folder anonymous users see |
| `anon_upload_enable=NO`, `anon_mkdir_write_enable=NO` | Anonymous users can't upload or create folders |
| `chroot_local_user=YES` | Local users are locked inside their home folder |
| `ssl_enable=YES` | Encrypt FTP (FTPS) |

```bash
nano /etc/vsftpd.conf
systemctl restart vsftpd      # restart, never stop, if it's critical
systemctl status vsftpd
```

**Don't delete the files in public FTP folders** (`/srv/ftp`, `/var/ftp`).
That cost -5 in the practice round. The script's media scan skips those
folders.

---

## 5. Software & Services

### Services
**What it is:** a service (daemon) is a background program, usually started
at boot by **systemd**.

**Why it matters:** every running service, especially one listening on the
network, is something an attacker can target. Disable what the README doesn't
need. The script only offers services from the `prohibited_services` list and
skips anything you marked critical.

```bash
systemctl list-units --type=service --state=running   # what's running
ss -tulnp                                              # what's listening on the network
systemctl disable --now <service>     # stop it now AND don't start at boot
systemctl status <service>
```

**What common services do** (and why they're often unwanted):

| Service | What it does | Why it's often removed |
|---|---|---|
| `nginx`, `apache2` | Web servers | Unneeded web server = extra attack surface |
| `squid` | Web proxy (relays/caches web traffic) | Can be abused to relay attacks or hide activity |
| `dovecot` | Email server (POP3/IMAP mailbox access) | Mail servers aren't needed on a workstation |
| `postfix`, `sendmail`, `exim4` | Email sending servers (SMTP) | Can be abused to send spam |
| `smbd`, `nmbd` (Samba) | Windows-style file sharing | Exposes files over the network |
| `vsftpd`, `pure-ftpd`, `proftpd` | FTP servers | Plain-text passwords. **Keep if the README says it's critical** |
| `tftpd-hpa`, `atftpd` | TFTP: file transfer with **no login at all** | Anyone can read/write files |
| `telnet`, `inetd`, `xinetd` | Old remote login / super-servers | Telnet sends everything in plain text; use SSH |
| `snmpd` | Network monitoring (SNMP) | Often leaks system details with default passwords |
| `nfs-server`, `rpcbind` | Unix network file sharing | Exposes files over the network |
| `bind9` / `named` | DNS server | Only needed if the machine answers DNS for others |
| `cups` | Printing | Usually harmless; disable only if allowed |
| `avahi-daemon` | Announces the machine on the local network | Leaks information; rarely needed |
| `x11vnc`, `vncserver` | Remote desktop (VNC) | Often weak or no password |
| `mysql`, `mariadb`, `postgresql` | Databases | Only if the README needs them |
| `openvpn` | VPN tunnel | Could be a hidden way into the network |
| `rsync` | File sync daemon | Can expose files if left running |

### Backdoor / Listener Check
**What it is:** a backdoor is a hidden program that lets an attacker connect
in. Often it's a small script (Python, Perl, netcat) listening on an odd port.

**Why it matters:** the practice round planted
`/usr/share/zod/kneelB4zod.py` on port **1337**, worth points both as a
forensics answer and for removing it.

The script lists every listening program and marks with `!!` anything run by
a script interpreter or netcat, or not installed by a package. For the ones
you pick, it shows what starts them, kills the process and offers to delete
the script.

```bash
ss -tlnp                         # listening TCP ports + process
ps -ef | grep python             # find the full command line
pkill -f <script-name>           # stop it (matches the full command line)
rm -f <path-to-script>
grep -rl <script-name> /etc/systemd /etc/cron* /var/spool/cron /etc/rc.local   # what restarts it?
```

### Prohibited Software
**Why it matters:** hacking tools and unneeded servers are scored as
"prohibited software". The script lists only the packages from
`prohibited_software` that are actually installed. You pick which to remove,
and apt shows everything that will go before asking.

```bash
dpkg -l | grep <name>              # is it installed?
apt purge <package>                # remove it and its config files
apt autoremove                     # remove leftover dependencies
```

**What common tools do:**

| Package | What it is |
|---|---|
| `john` (John the Ripper), `hashcat`, `ophcrack`, `fcrackzip` | Password crackers |
| `hydra`, `medusa`, `doona` | Brute-force login attackers (doona is a fuzzer that sends junk input to crash services) |
| `nmap`, `zenmap`, `xprobe`, `xprobe2` | Network/port scanners and OS fingerprinting |
| `wireshark`, `tshark` | Packet sniffers that capture network traffic (sometimes needed for forensics; remove after) |
| `netcat`, `ncat` | Raw network connections, a common backdoor tool. **Note:** `netcat-openbsd` is part of a normal Ubuntu install |
| `aircrack-ng`, `kismet` | Wi-Fi cracking / sniffing |
| `ettercap` | Man-in-the-middle attack tool |
| `nikto`, `sqlmap` | Web vulnerability scanners / SQL injection |
| `deluge`, `transmission`, `qbittorrent` | BitTorrent clients (piracy risk) |

Loose files count too, e.g. the `pyrdp-master.zip` archive in `/usr/games`.
The Game Software function lists files there, and `locate *.zip` helps find
others.

### Game Software
Games are usually not work-related and the README forbids them. The script
looks for:
- packages in the `games` section, plus names from `game_keywords`
- snaps and flatpaks
- files in `/usr/games`
- desktop shortcuts with `Categories=Game`

```bash
dpkg-query -W -f='${Section} ${Package}\n' | grep games
ls /usr/games /usr/local/games
apt purge <game-package>
```

---

## 6. Files

### Prohibited Media Files
Music, video and similar files are "non-work-related media" in most READMEs.
They can also exploit media players, and pirated media is a legal problem.
The script asks which file types to search for, lists matches with their
size and owner, and you pick which to delete. FTP share folders are skipped.

```bash
locate '*.ogg'                  # fast (uses a database; run updatedb first)
find /home -type f \( -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.ogg' \)
rm -i <file>
```

### Cron Jobs Review
**What it is:** **cron** runs commands on a schedule.

**Why it matters:** attackers use cron to restart backdoors or re-add users.

| Place | What it holds |
|---|---|
| `/etc/crontab`, `/etc/cron.d/` | System-wide jobs |
| `/etc/cron.hourly`, `cron.daily`, `cron.weekly`, `cron.monthly` | Scripts run on that schedule |
| `/var/spool/cron/crontabs/<user>` | Each user's own jobs |
| `/etc/rc.local`, `/etc/init.d/` | Things started at boot |

```bash
crontab -l -u <user>             # view a user's jobs
crontab -r -u <user>             # remove them
# Optional allow-list: only users listed may use cron/at
echo root > /etc/cron.allow; echo root > /etc/at.allow; chmod 600 /etc/cron.allow /etc/at.allow
```

### File Permissions
Permission numbers are read as owner / group / everyone: 6 = read+write,
4 = read, 0 = nothing.

| File | Should be | Why |
|---|---|---|
| `/etc/shadow`, `/etc/gshadow` | `640 root:shadow` | Holds password hashes; ordinary users must not read it |
| `/etc/passwd`, `/etc/group` | `644 root:root` | Everyone may read it; only root may change it |
| `/etc/sudoers` | `440 root:root` | Read-only, even for root, to prevent accidents |

```bash
stat -c '%a %U:%G %n' /etc/shadow
chmod 640 /etc/shadow && chown root:shadow /etc/shadow
find /etc -type f -perm -0002          # world-writable files (should be none)
find / -xdev -perm -4000 -type f       # SUID programs: they run as their owner (often root); a planted one is a backdoor
```

---

## 7. Malware & Auditing

| Tool | What it does |
|---|---|
| **ClamAV** (`clamav`, GUI `clamtk`) | Antivirus. `freshclam` downloads the latest virus definitions; `clamscan -r -i /home` scans and lists infected files |
| **auditd** | Records security events (logins, file changes, use of privileges) for later investigation |
| **chkrootkit**, **rkhunter** | Look for rootkits: malware that hides itself inside the system |

```bash
apt install clamav && systemctl stop clamav-freshclam && freshclam && systemctl start clamav-freshclam
clamscan -r -i /home
apt install auditd && systemctl enable --now auditd
apt install --no-install-recommends chkrootkit && chkrootkit -q
apt install --no-install-recommends rkhunter && rkhunter --update && rkhunter --check --sk
```

---

## 8. Forensics Helper (read-only)

These menu items change nothing. They speed up common forensics questions.

| Item | Manual equivalent | Typical question |
|---|---|---|
| Listening ports & processes | `ss -tulnp`, `ps -ef` | "What folder contains the backdoor?" |
| Find files | `locate <name>`, `find / -iname '*name*'` | "Where is override.txt?" |
| Base64 decode | `base64 -d <<< 'VmlzaW9uc0FjYWRlbXk='` | Encoded passphrases |
| File hashes | `md5sum`, `sha256sum <file>` | "What is the MD5 of…?" |
| User / group lookup | `id`, `getent group`, `chage -l` | "Which groups is X in?" |
| Recently modified files | `find /home -mtime -7` | "What was recently changed?" |

Other useful forensics tools (install only if allowed; remove afterwards if
prohibited):
- `tshark -q -z follow,tcp,ascii,<stream> -r <file.pcap>` reads a network
  capture.
- `steghide extract -sf <image> -p <passphrase>` pulls data hidden inside an
  image.
