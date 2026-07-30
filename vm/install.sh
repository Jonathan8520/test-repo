#!/bin/bash
# Installe (ou met a jour) le grabber ARM sur cette VM.
#
#   curl -sL https://raw.githubusercontent.com/Jonathan8520/test-repo/main/vm/install.sh -o install.sh
#   sudo bash install.sh
#
# Relancer cette meme commande met simplement le script a jour et redemarre
# le service : c'est sans risque.
#
# Desinstallation :
#   sudo systemctl disable --now oci-grabber && sudo rm -rf /opt/oci-grabber \
#     /etc/systemd/system/oci-grabber.service

set -e

if [ "$(id -u)" != "0" ]; then
  echo "A lancer avec sudo : sudo bash install.sh"
  exit 1
fi

echo "== 1/4 Swap (1 Go) =="
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "   swap active"
else
  echo "   swap deja present"
fi

echo "== 2/4 Dependances + OCI CLI =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq jq curl python3-venv >/dev/null
mkdir -p /opt/oci-grabber
if [ ! -x /opt/oci-grabber/venv/bin/oci ]; then
  python3 -m venv /opt/oci-grabber/venv
  /opt/oci-grabber/venv/bin/pip install -q --upgrade pip
  /opt/oci-grabber/venv/bin/pip install -q oci-cli
fi
echo "   OCI CLI : $(/opt/oci-grabber/venv/bin/oci --version 2>/dev/null || echo 'echec')"

echo "== 3/4 Script de chasse =="
curl -sL https://raw.githubusercontent.com/Jonathan8520/test-repo/main/vm/grab.sh \
  -o /opt/oci-grabber/grab.sh
chmod +x /opt/oci-grabber/grab.sh
touch /var/log/oci-grabber.log

echo "== 4/4 Service systemd =="
# grab.sh boucle lui-meme en interne (la decouverte n'est faite qu'une fois),
# donc systemd le lance directement, sans boucle shell externe.
cat > /etc/systemd/system/oci-grabber.service <<'UNIT'
[Unit]
Description=OCI ARM capacity grabber
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/oci-grabber/grab.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable oci-grabber >/dev/null 2>&1
systemctl restart oci-grabber

echo
echo "=== TERMINE ==="
sleep 3
systemctl is-active oci-grabber && echo "Service actif."
echo
echo "Suivre les tentatives en direct :  sudo tail -f /var/log/oci-grabber.log"
