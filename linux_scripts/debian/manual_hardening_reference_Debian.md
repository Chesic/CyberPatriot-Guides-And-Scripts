# Debian Hardening Reference (Manual)

A step-by-step guide to securing a Debian image by hand.
Each section explains **what the thing is**, **why it matters**, and gives
**simple commands** to fix it.

Words in `<angle brackets>` are placeholders. Replace them, e.g. `<user>`
becomes `jonas`.

**Editing files with nano:** open the file with `sudo nano <file>`, use the
arrow keys to find the line, change it, then press **Ctrl+O**, **Enter** to
save and **Ctrl+X** to exit. **Ctrl+W** searches for text.

> **Before you start**
> 1. **Read the README.** It lists the authorized users, the admins, the
>    critical services that must stay running, and the software you must keep.
> 2. **Answer the Forensics Questions first.** Fixing things can destroy the
>    evidence a question asks about.
> 3. **Never stop or remove a critical service** from the README (e.g. vsftpd
>    or SSH). That costs points.

### Getting admin rights on Debian
Debian doesn't always set up `sudo`. If `sudo` says "command not found" or
"user is not in the sudoers file":

```bash
su -                          # become root (uses the root password from the README)
apt install sudo              # install sudo if it's missing
adduser <your-user> sudo      # let your user use sudo
exit                          # leave root
```

Log out and back in, then check with `sudo whoami`; it should print `root`.

---

## 1. Users & Groups

### Users and administrators
**What it is:** every person who can log in has an account. Members of the
`sudo` group are **administrators** and can run any command as root (the
all-powerful system account).

**Why it matters:** extra accounts are extra passwords to guess, and extra
admins are extra ways to take over the whole computer. Compare against the
README:
- **Delete** users who aren't listed.
- **Remove admin rights** from users who aren't listed as admins.
- **Add** listed users who are missing.

```bash
cat /etc/passwd                     # all accounts (real users usually have UID 1000+)
getent group sudo                   # who is an admin
sudo deluser --remove-home <user>   # delete an unauthorized user
sudo gpasswd -d <user> sudo         # take away admin rights
sudo adduser <user> sudo            # give admin rights
sudo adduser <user>                 # create a missing user (asks for a password)
```

**Hidden root accounts:** only `root` should have UID `0`, the third field in
`/etc/passwd`. Look for any other line like `name:x:0:...`.

**Lock root:** nobody should log in as root directly. Admins use `sudo`
instead.

**On Debian, lock root only after an admin can use sudo.** If root is the
only way in and you lock it, you're locked out of admin tasks. First run
`sudo whoami` as an admin user and make sure it prints `root`, then:

```bash
sudo passwd -l root
```

### Groups
**What it is:** a group is a named set of users. Permissions can be given to
the whole group at once.

**Why it matters:** READMEs often ask you to create a group and add people to
it.

```bash
sudo addgroup <group>                 # create a group
sudo gpasswd -a <user> <group>        # add a user to it
sudo gpasswd -d <user> <group>        # remove a user from it
getent group <group>                  # see who's in it
```

### Weak or blank passwords
**What it is:** password hashes (scrambled passwords) are stored in
`/etc/shadow`.

**Why it matters:** an account with a blank or easy password can be logged
into by anyone.

```bash
sudo passwd -S <user>      # P = has password, NP = NO password, L = locked
sudo passwd <user>         # set a new, strong password
```

A strong password has 10+ characters with upper and lower case letters, a
number and a symbol, e.g. `Cyb3rPatr!0t$`.

### Sudo rules
**What it is:** `/etc/sudoers` (and files in `/etc/sudoers.d/`) control who
can use `sudo`.

**Why it matters:**
- `NOPASSWD` lets someone become root **without a password**.
- `!authenticate` turns password checks off.

```bash
sudo visudo                          # ALWAYS edit sudoers with visudo, it checks for mistakes
ls /etc/sudoers.d                    # also check these files: sudo visudo -f /etc/sudoers.d/<file>
```

Find lines containing `NOPASSWD:` and delete that word, so
`user ALL=(ALL) NOPASSWD: ALL` becomes `user ALL=(ALL) ALL`. Delete any
`Defaults !authenticate` line.

---

## 2. Password & Login Policy

### Password age rules
**What it is:** `/etc/login.defs` holds the default password rules for **new**
accounts.

| Line | Meaning |
|---|---|
| `PASS_MAX_DAYS 90` | Must change the password at least every 90 days |
| `PASS_MIN_DAYS 10` | Can't change it again for 10 days (stops cycling back to an old one) |
| `PASS_WARN_AGE 7` | Warning 7 days before it expires |

```bash
sudo nano /etc/login.defs
```

Existing users keep their old rules, so set them for each user too:

```bash
sudo chage -M 90 -m 10 -W 7 <user>
sudo chage -l <user>                  # check it
```

### Password length, history and blank passwords (PAM)
**What it is:** **PAM** (Pluggable Authentication Modules) is how Linux
checks passwords. Its settings live in `/etc/pam.d/`.

**Minimum length and remembered passwords:**

```bash
sudo nano /etc/pam.d/common-password
```

Find the line with `pam_unix.so` and add `minlen=10 remember=5` to the end:

```
password  [success=1 default=ignore]  pam_unix.so obscure yescrypt minlen=10 remember=5
```

- `minlen=10` means passwords must be at least 10 characters.
- `remember=5` means users can't reuse their last 5 passwords.

**No blank-password logins:**

```bash
sudo nano /etc/pam.d/common-auth
```

On the `pam_unix.so` line, delete the word `nullok`. `nullok` lets accounts
with an **empty** password log in.

### Account lockout
**What it is:** after several wrong passwords, the account gets locked for a
while.

**Why it matters:** this stops brute-force attacks, where a program tries
thousands of passwords.

Create three files:

```bash
sudo nano /usr/share/pam-configs/faillock
```
```
Name: Lockout on failed logins
Default: no
Priority: 0
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail
```

```bash
sudo nano /usr/share/pam-configs/faillock_reset
```
```
Name: Reset lockout on success
Default: no
Priority: 0
Auth-Type: Additional
Auth:
	required	pam_faillock.so authsucc
```

```bash
sudo nano /usr/share/pam-configs/faillock_notify
```
```
Name: Notify on account lockout
Default: no
Priority: 1024
Auth-Type: Primary
Auth:
	requisite	pam_faillock.so preauth
```

Then turn them on:

```bash
sudo pam-auth-update
```

Use the arrow keys and Space to tick **Notify on account lockout**, **Reset
lockout on success** and **Lockout on failed logins**, then select **OK**.

### Login screen
**What it is:**
- **GDM** is the login screen on Debian with GNOME (the default desktop).
- **LightDM** is the login screen on Debian with Xfce, MATE or LXDE.

**Why it matters:**
- A guest account needs no password.
- Auto-login lets anyone in.
- Showing the user list gives attackers valid usernames.

LightDM:

```bash
sudo nano /etc/lightdm/lightdm.conf
```

Under `[Seat:*]`, add or change these lines:

```
allow-guest=false
greeter-hide-users=true
greeter-show-manual-login=true
autologin-user=none
```

GDM: on Debian the file is `/etc/gdm3/daemon.conf` (not `custom.conf`):

```bash
sudo nano /etc/gdm3/daemon.conf
```

Under `[daemon]`, set `AutomaticLoginEnable=false` and
`TimedLoginEnable=false`. To hide the user list, in
`/etc/gdm3/greeter.dconf-defaults` under `[org/gnome/login-screen]` set
`disable-user-list=true`, then run `sudo dconf update`.

Changes take effect after a reboot.

---

## 3. Updates

**Why it matters:** updates fix known security holes. Attackers look for
computers that haven't installed them.

**Make sure security updates are turned on.** Debian gets security fixes
from a separate "debian-security" source. If it's missing, those updates
never install.

```bash
grep -r security /etc/apt/sources.list /etc/apt/sources.list.d/
```

If nothing shows up (or the line starts with `#`), add it. Replace
`bookworm` with your release name (shown by `cat /etc/os-release`):

```bash
sudo nano /etc/apt/sources.list
```
```
deb http://security.debian.org/debian-security bookworm-security main
```

Then install the updates:

```bash
sudo apt update                   # get the list of new versions
sudo apt full-upgrade -y          # install all updates
sudo apt install --only-upgrade firefox-esr   # update just one program (Debian's Firefox is firefox-esr)
```

- If apt asks whether to keep a config file, keeping your current version is
  usually safest.
- **Automatic updates:**

  ```bash
  sudo apt install unattended-upgrades
  sudo dpkg-reconfigure -plow unattended-upgrades    # choose "Yes"
  ```

  On GNOME you can also use Software → menu → Update Preferences →
  turn on automatic updates.

---

## 4. Network & Firewall

### Firewall (UFW)
**What it is:** a firewall blocks network connections you didn't allow.
**UFW** ("Uncomplicated Firewall") is the easy firewall. Debian often doesn't
have it installed, so install it first.

**Why it matters:** with the firewall on, only services you allow can be
reached from the network. Allow the ports critical services need **before**
turning it on.

```bash
sudo apt install ufw         # Debian usually needs this first
sudo ufw allow ssh           # only if SSH is a critical service
sudo ufw allow ftp           # only if FTP is a critical service
sudo ufw enable
sudo ufw status verbose
```

### SSH (remote login)
**What it is:** **SSH** (`openssh-server`) lets people log in to the computer
over the network.

**Why it matters:** an SSH server faces the network, so weak settings can let
an attacker in. If the README doesn't need SSH, remove it with
`sudo apt purge openssh-server`. If it does need it:

```bash
sudo nano /etc/ssh/sshd_config
```

| Set this | Why |
|---|---|
| `PermitRootLogin no` | Attackers always try root first |
| `PermitEmptyPasswords no` | No logging in with a blank password |
| `LoginGraceTime 60` | Disconnect people who don't log in within 60 seconds |
| `X11Forwarding no` | Don't send graphical apps over SSH |
| `UsePAM yes` | Use the system's password and lockout rules |

If a line starts with `#`, it's switched off: remove the `#` and set the
value. Then:

```bash
sudo sshd -t                     # check for mistakes (no output = OK)
sudo systemctl restart ssh
```

### Kernel security settings (sysctl)
**What it is:** settings that change how the Linux core (kernel) behaves.
They're stored in `/etc/sysctl.conf` and in files under `/etc/sysctl.d/`.

```bash
sudo nano /etc/sysctl.conf
```

**Debian 13 has no `/etc/sysctl.conf`.** Create your own file instead. The
`99-zz` name makes it load last, so it wins:

```bash
sudo nano /etc/sysctl.d/99-zz-hardening.conf
```

Bad values can also be planted in other files. Check them, and fix any you
find:

```bash
grep -r randomize_va_space /etc/sysctl.conf /etc/sysctl.d/
grep -r syncookies /etc/sysctl.conf /etc/sysctl.d/
```

Change or add these lines. If one exists with a different number, change the
number.

| Line | What it does |
|---|---|
| `kernel.randomize_va_space = 2` | **ASLR**: puts programs at random memory spots so exploits are harder |
| `net.ipv4.tcp_syncookies = 1` | **SYN cookies**: protects against SYN-flood denial-of-service attacks |
| `net.ipv4.tcp_rfc1337 = 1` | Ignores fake "reset" packets meant to cut your connections |
| `net.ipv4.ip_forward = 0` | Don't act as a router |
| `net.ipv4.conf.all.accept_redirects = 0` | Ignore messages trying to reroute your traffic |
| `net.ipv4.conf.all.send_redirects = 0` | Don't send reroute messages (only routers should) |
| `net.ipv4.conf.all.rp_filter = 1` | Drop packets with faked source addresses |
| `net.ipv4.conf.all.accept_source_route = 0` | Ignore packets that choose their own path |
| `net.ipv4.conf.all.log_martians = 1` | Log packets with impossible addresses |
| `net.ipv4.icmp_echo_ignore_broadcasts = 1` | Ignore broadcast pings (Smurf attack) |

Apply them:

```bash
sudo sysctl --system
sysctl kernel.randomize_va_space     # check one setting
```

### FTP server (vsftpd)
**What it is:** **FTP** shares files over the network. **vsftpd** is the
common FTP server. FTP sends passwords as plain readable text.

**Why it matters:** if the README says FTP is critical, **don't remove or
stop it**. Set it up the way the README asks instead.

```bash
sudo nano /etc/vsftpd.conf
```

| Line | Meaning |
|---|---|
| `anonymous_enable=YES` / `NO` | Allow logging in as "anonymous" (no real account) |
| `local_enable=YES` / `NO` | Allow real users to log in (NO keeps their passwords off the network) |
| `anon_root=/var/ftp` | Folder anonymous users see |
| `anon_upload_enable=NO` | Anonymous users can't upload |
| `chroot_local_user=YES` | Real users stay inside their home folder |

Example, "users must log in as anonymous only":
`anonymous_enable=YES`, `local_enable=NO`, `anon_root=/var/ftp`.

```bash
sudo systemctl restart vsftpd    # restart (never stop) after editing
```

**Don't delete work files in the FTP folders** (`/srv/ftp`, `/var/ftp`).

---

## 5. Software & Services

### Services
**What it is:** a service is a program that runs in the background, often
waiting for network connections.

**Why it matters:** every unneeded service is something an attacker can
target. Stop and disable services the README doesn't need.

```bash
systemctl list-units --type=service --state=running   # what's running
sudo systemctl disable --now <service>                # stop it and keep it off after reboot
systemctl status <service>                            # check it
```

**What common services do:**

| Service | What it does | Usually remove? |
|---|---|---|
| `nginx`, `apache2` | Web servers (host websites) | Yes, unless the README needs a website |
| `squid` | Web proxy (passes web traffic through itself) | Yes, it can hide or relay attacks |
| `dovecot` | Email mailbox server (POP3/IMAP) | Yes on a normal workstation |
| `exim4` | Email sending server, **installed by default on Debian** | Usually safe to disable on a workstation unless the README needs mail |
| `postfix`, `sendmail` | Email sending servers | Yes, they can be used to send spam |
| `smbd`, `nmbd` (Samba) | Windows-style file sharing | Yes, unless file sharing is required |
| `vsftpd`, `pure-ftpd`, `proftpd` | FTP file servers | **Check the README**: often critical |
| `tftpd-hpa` | TFTP: file transfer with no password at all | Yes |
| `telnet`, `xinetd`, `inetd` | Old remote login, no encryption | Yes, use SSH instead |
| `snmpd` | Network monitoring | Yes, it leaks system information |
| `nfs-server`, `rpcbind` | Unix file sharing | Yes, unless required |
| `bind9` | DNS server (turns names into IP addresses) | Yes, unless required |
| `x11vnc`, `vncserver` | Remote desktop | Yes, often weak passwords |
| `mysql`, `postgresql` | Databases | Only keep if the README needs them |
| `cups` | Printing | Usually fine to leave |
| `avahi-daemon` | Announces the computer on the local network | Can be disabled |

### Backdoors (hidden listening programs)
**What it is:** a backdoor is a hidden program that lets an attacker connect
in. Often it's a Python, Perl or netcat script listening on an odd port like
1337.

```bash
sudo ss -tlnp                # listening ports and the program behind each
ps -ef | grep python         # see the full command and file path
sudo pkill -f <script-name>  # stop it, e.g. sudo pkill -f kneelB4zod.py
sudo rm <path-to-script>     # delete it
```

If it comes back, check what starts it:

```bash
ls /etc/systemd/system
sudo crontab -l
ls /etc/cron.d
```

### Prohibited software
**Why it matters:** hacking tools and unneeded programs count as prohibited
software. Remove anything the README doesn't allow.

```bash
apt list --installed | grep <name>    # is it installed?
sudo apt purge <package>              # remove it and its settings
sudo apt autoremove                   # clean up leftovers
```

**What common tools are:**

| Program | What it does |
|---|---|
| `john`, `hashcat`, `ophcrack`, `fcrackzip` | Password crackers |
| `hydra`, `medusa` | Guess logins over the network (brute force) |
| `doona` | Fuzzer: sends junk data to crash programs |
| `nmap`, `zenmap`, `xprobe` | Network scanners: find computers and open ports |
| `wireshark`, `tshark` | Capture network traffic (may be needed for a forensics question; remove after if prohibited) |
| `netcat` / `nc` | Raw network connections, often used as a backdoor |
| `aircrack-ng`, `kismet` | Wi-Fi cracking |
| `ettercap` | Intercepts other people's traffic (man-in-the-middle) |
| `nikto`, `sqlmap` | Website attack tools |
| `deluge`, `transmission`, `qbittorrent` | BitTorrent (piracy) |

Also check for downloaded tools sitting as files, e.g. a `.zip` in
`/usr/games`:

```bash
locate '*.zip'
sudo rm <file>
```

### Games
Games aren't work-related and are usually prohibited.

```bash
ls /usr/games                     # game programs
apt list --installed | grep -i game
sudo apt purge <game>             # e.g. aisleriot, gnome-mines, gnome-sudoku
```

---

## 6. Files

### Prohibited media
Music and video files (`.mp3`, `.mp4`, `.ogg`, `.wav`, `.avi`, `.mkv`…) are
"non-work-related media" in most READMEs.

```bash
sudo updatedb                     # refresh the file database
locate '*.mp3'
locate '*.ogg'
sudo rm <file>
```

Don't delete files from the public FTP folders. Those are work files.

### Scheduled tasks (cron)
**What it is:** **cron** runs commands on a schedule.

**Why it matters:** attackers use it to restart backdoors.

```bash
cat /etc/crontab                  # system schedule
ls /etc/cron.d /etc/cron.daily    # more scheduled scripts
sudo crontab -l -u <user>         # one user's scheduled jobs
sudo crontab -r -u <user>         # delete that user's jobs (if malicious)
```

### File permissions
Permission numbers are read as owner / group / everyone: 6 = read+write,
4 = read, 0 = nothing.

| File | Should be | Why |
|---|---|---|
| `/etc/shadow` | `640` | Holds password hashes; regular users must not read it |
| `/etc/passwd`, `/etc/group` | `644` | Everyone may read; only root may change |
| `/etc/sudoers` | `440` | Read-only |

```bash
ls -l /etc/shadow                 # -rw-r----- means 640
sudo chmod 640 /etc/shadow
sudo chmod 644 /etc/passwd
```

---

## 7. Malware & Auditing

| Tool | What it does |
|---|---|
| **ClamAV** | Antivirus scanner |
| **auditd** | Keeps a log of security events (logins, file changes) |
| **chkrootkit** | Looks for rootkits: malware that hides itself |

```bash
sudo apt install clamav
sudo systemctl stop clamav-freshclam
sudo freshclam                    # download the latest virus definitions
sudo clamscan -r -i /home         # scan home folders, list infected files

sudo apt install auditd
sudo systemctl enable --now auditd

sudo apt install chkrootkit
sudo chkrootkit
```

---

## 8. Forensics Question Tips

| Task | Command |
|---|---|
| Which program is listening on a port | `sudo ss -tlnp` |
| Full command line of a process | `ps -ef \| grep <name>` |
| Find a file | `locate <name>` |
| Decode base64 text | `echo '<text>' \| base64 -d` |
| MD5 hash of a file | `md5sum <file>` |
| User info / groups | `id <user>` and `getent group <group>` |
| Recently changed files | `find /home -mtime -7` |
| Read a network capture | `tshark -r <file.pcap>` |
| Extract data hidden in an image | `steghide extract -sf <image>` |

Remember to **save** the Forensics Question file after typing the answer.
