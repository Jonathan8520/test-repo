#!/bin/bash
# Installe le grabber ARM sur cette VM (a lancer avec sudo, une seule fois).
#
#   curl -sL https://raw.githubusercontent.com/Jonathan8520/test-repo/main/vm/install.sh -o install.sh
#   sudo bash install.sh
#
# Ce script :
#   1. cree 1 Go de swap (la VM n'a que 1 Go de RAM, c'est juste pour l'install)
#   2. installe l'OCI CLI dans un venv isole
#   3. installe /opt/oci-grabber/grab.sh
#   4. cree un service systemd qui tente les cibles ARM toutes les 30 s
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

echo "== 4/4 Service systemd (toutes les 30 s) =="
cat > /etc/systemd/system/oci-grabber.service <<'UNIT'
[Unit]
Description=OCI ARM capacity grabber
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /opt/oci-grabber/grab.sh; sleep 30; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now oci-grabber

echo
echo "=== TERMINE ==="
systemctl is-active oci-grabber && echo "Service actif."
echo
echo "Verifier le test d'authentification (doit afficher un OCID) :"
/opt/oci-grabber/venv/bin/oci --auth instance_principal iam region list \
  --query 'data[0].key' --raw-output 2>&1 | head -3
echo
echo "Suivre les tentatives en direct :  sudo tail -f /var/log/oci-grabber.log"
