# Manual Hardening Reference

These are checklist items you're handling by hand rather than through
`cyberPatriot_Script.sh`. Each section has a quick explanation and
copy-pasteable commands to run yourself (as root / with `sudo`).

## User Account Management

`cyberPatriot_Script.sh` only *reports* on accounts (UID 0 accounts,
accounts with empty passwords) - it does not lock, unlock, or delete
anything. Use these commands to act on what it flags, once you've
confirmed which accounts are actually unauthorized.

```bash
# List all local accounts with UID and shell (spot anything unexpected)
awk -F: '{print $1, $3, $7}' /etc/passwd

# Lock an account (disables password login, keeps the account/data intact)
passwd -l <username>

# Unlock a previously locked account
passwd -u <username>

# Set/reset a password for an account
passwd <username>

# Force an account to change its password at next login
chage -d 0 <username>

# Delete an account (keep home directory)
userdel <username>

# Delete an account AND its home directory/mail spool
userdel -r <username>

# Remove a user from a group (e.g. drop unauthorized sudo access)
gpasswd -d <username> sudo

# Check an account's password status (locked/unlocked/no password)
passwd -S <username>
```

## Unwanted / Insecure Services

Check what's listening and installed, then remove or disable anything
not required by the scenario.

```bash
# List listening ports and the process/service behind each one
ss -tulnp

# List services enabled at boot
systemctl list-unit-files --state=enabled

# Commonly prohibited services - check if installed, then purge if unneeded
dpkg -l | grep -Ei 'telnet|vsftpd|nis|rsh|xinetd'

# Example: remove telnet server and client
apt remove --purge -y telnetd telnet

# Example: remove FTP server
apt remove --purge -y vsftpd

# Disable (but not remove) a service
systemctl disable --now <service-name>
```

## auditd

Installs Linux audit framework so security-relevant events get logged.

```bash
apt install -y auditd audispd-plugins
systemctl enable --now auditd
systemctl status auditd
```

## Malware / Rootkit Scan

```bash
# rkhunter
apt install -y rkhunter
rkhunter --update
rkhunter --propupd
rkhunter --check --sk

# chkrootkit
apt install -y chkrootkit
chkrootkit
```

## Network / Kernel Hardening (sysctl)

Add these to `/etc/sysctl.conf` (or a file under `/etc/sysctl.d/`), then
apply with `sysctl -p`.

```
# Disable IP forwarding (unless this box is meant to route traffic)
net.ipv4.ip_forward = 0

# Ignore ICMP broadcast requests (mitigates Smurf-style attacks)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable SYN cookies (mitigates SYN flood attacks)
net.ipv4.tcp_syncookies = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Disable ICMP redirect acceptance
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Log packets with impossible/spoofed addresses
net.ipv4.conf.all.log_martians = 1
```

Apply the changes:

```bash
sysctl -p
```

## Cron / At Restrictions

Restrict which users can schedule cron/at jobs by using an allow-list.
If `cron.allow` / `at.allow` exist, only users listed in them may use
`cron`/`at`; everyone else is denied.

```bash
# Check if the allow files exist
ls -l /etc/cron.allow /etc/at.allow

# Create them and add only the users who should have access
echo "root" > /etc/cron.allow
echo "root" > /etc/at.allow
chmod 600 /etc/cron.allow /etc/at.allow

# Make sure the old-style deny files aren't overriding things
cat /etc/cron.deny /etc/at.deny 2>/dev/null
```
