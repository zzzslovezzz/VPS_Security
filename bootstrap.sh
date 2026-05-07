#!/usr/bin/env bash
set -euo pipefail

USER_NAME="leo"
USER_PASSWORD="1234"
SSH_PORT="1022"
PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1QwdX1h/DsfDDjwVVsHYSrFb7ZOfbWN0UIpxlg8EFE leo@vps'
ACME_EMAIL="slove,mowe@gmail.com"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

echo "[1/10] Updating system..."
apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -y
apt install -y sudo curl wget vim ufw fail2ban unattended-upgrades socat

echo "[2/10] Creating user ${USER_NAME}..."
if ! id "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$USER_NAME"
fi

echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
usermod -aG sudo "$USER_NAME"

echo "[3/10] Enabling passwordless sudo..."
echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}"
chmod 440 "/etc/sudoers.d/${USER_NAME}"
visudo -cf "/etc/sudoers.d/${USER_NAME}"

echo "[4/10] Installing SSH key..."
mkdir -p "/home/${USER_NAME}/.ssh"
echo "$PUBLIC_KEY" > "/home/${USER_NAME}/.ssh/authorized_keys"
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.ssh"
chmod 700 "/home/${USER_NAME}/.ssh"
chmod 600 "/home/${USER_NAME}/.ssh/authorized_keys"

echo "[5/10] Hardening SSH..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%F-%H%M%S)"

for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] || continue
  sed -i \
    -e 's/^[[:space:]]*Port[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*PermitRootLogin[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*PubkeyAuthentication[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*X11Forwarding[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*MaxAuthTries[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*ClientAliveInterval[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*ClientAliveCountMax[[:space:]].*/# &/' \
    -e 's/^[[:space:]]*AllowUsers[[:space:]].*/# &/' \
    "$f"
done

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${USER_NAME}
EOF

sshd -t

echo "[6/10] Configuring UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw --force enable

echo "[7/10] Optional SSL certificate..."
echo
read -rp "Enter domain for SSL certificate, or press Enter to skip: " SSL_DOMAIN

if [ -n "$SSL_DOMAIN" ]; then
  echo "[SSL] Installing acme.sh..."

  if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
  fi

  echo "[SSL] Opening port 80 temporarily..."
  ufw allow 80/tcp

  echo "[SSL] Issuing certificate for ${SSL_DOMAIN}..."
  /root/.acme.sh/acme.sh --issue --standalone -d "$SSL_DOMAIN" --keylength ec-256

  echo "[SSL] Installing certificate files..."
  mkdir -p "/etc/ssl/${SSL_DOMAIN}"

  /root/.acme.sh/acme.sh --install-cert -d "$SSL_DOMAIN" --ecc \
    --key-file "/etc/ssl/${SSL_DOMAIN}/privkey.key" \
    --fullchain-file "/etc/ssl/${SSL_DOMAIN}/fullchain.pem"

  echo "[SSL] Closing port 80..."
  ufw delete allow 80/tcp || true

  echo "[SSL] Certificate installed:"
  echo "  /etc/ssl/${SSL_DOMAIN}/privkey.key"
  echo "  /etc/ssl/${SSL_DOMAIN}/fullchain.pem"
else
  echo "[SSL] Skipped."
fi

echo "[8/10] Restarting SSH..."
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl restart ssh

echo "[9/10] Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "[10/10] Enabling unattended upgrades and sysctl hardening..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/sysctl.d/99-security.conf <<EOF
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0

net.ipv4.conf.all.log_martians=1
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

# Disable regular ping replies
net.ipv4.icmp_echo_ignore_all=1
EOF

sysctl --system >/dev/null

echo
echo "DONE."
echo "Test SSH:"
echo "ssh -p ${SSH_PORT} ${USER_NAME}@SERVER_IP"
echo
echo "UFW status:"
ufw status
echo
echo "If SSL was issued, cert files are here:"
echo "/etc/ssl/DOMAIN/privkey.key"
echo "/etc/ssl/DOMAIN/fullchain.pem"
