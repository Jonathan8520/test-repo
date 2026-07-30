#!/bin/bash
# Chasse les tranches ARM Always Free depuis la VM elle-meme.
#
# Aucune cle stockee : la VM s'authentifie en "instance principal".
# Tout est auto-decouvert via le service de metadonnees (compartiment, AD,
# sous-reseau) et la cle SSH est reprise depuis authorized_keys.
#
# Cibles (somme = 4 OCPU / 24 Go = maximum gratuit) :
#   arm-vm-1 = 1 OCPU / 6 Go
#   arm-vm-2 = 1 OCPU / 6 Go
#   arm-vm-3 = 2 OCPU / 12 Go
#
# Garde-fous anti-facturation :
#   - budget = 4 - (OCPU ARM deja utilises), recalcule a chaque passage
#   - decremente apres chaque creation reussie dans le meme passage
#   - une cible n'est tentee que si aucune instance de ce nom n'existe

set +e

OCI=/opt/oci-grabber/venv/bin/oci
MD="http://169.254.169.254/opc/v2"
HDR="Authorization: Bearer Oracle"
LOG=/var/log/oci-grabber.log

log() { echo "$(date -Is) $*" >> "$LOG"; }

AUTH="--auth instance_principal"

INST=$(curl -s -H "$HDR" "$MD/instance/")
COMP=$(echo "$INST" | jq -r .compartmentId 2>/dev/null)
AD=$(echo "$INST"   | jq -r .availabilityDomain 2>/dev/null)
VNIC=$(curl -s -H "$HDR" "$MD/vnics/" | jq -r '.[0].vnicId' 2>/dev/null)

[ -z "$COMP" ] || [ "$COMP" = "null" ] && { log "ERREUR: compartiment introuvable"; exit 1; }
[ -z "$AD" ]   || [ "$AD" = "null" ]   && { log "ERREUR: AD introuvable"; exit 1; }

SUBNET=$($OCI $AUTH network vnic get --vnic-id "$VNIC" \
  --query 'data."subnet-id"' --raw-output 2>/dev/null)
[ -z "$SUBNET" ] && { log "ERREUR: sous-reseau introuvable (politique IAM ?)"; exit 1; }

PUBKEY=$(head -1 /home/ubuntu/.ssh/authorized_keys 2>/dev/null)
[ -z "$PUBKEY" ] && { log "ERREUR: cle SSH publique introuvable"; exit 1; }

# --- Budget ARM restant ---
CNT=$($OCI $AUTH compute instance list -c "$COMP" --all \
  --query "length(data[?\"shape\"=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
  --raw-output 2>/dev/null)
if [ "$CNT" = "0" ]; then
  USED=0
else
  USED=$($OCI $AUTH compute instance list -c "$COMP" --all \
    --query "sum(data[?\"shape\"=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].\"shape-config\".ocpus)" \
    --raw-output 2>/dev/null)
fi
case "$USED" in ''|*[!0-9.]*) USED=4 ;; esac
BUDGET=$(awk -v u="$USED" 'BEGIN{printf "%d", 4-u}')
[ "$BUDGET" -le 0 ] && exit 0

IMG=$($OCI $AUTH compute image list -c "$COMP" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED \
  --query 'data[0].id' --raw-output 2>/dev/null)
[ -z "$IMG" ] && { log "ERREUR: image ARM introuvable"; exit 1; }

for T in "arm-vm-1 1 6" "arm-vm-2 1 6" "arm-vm-3 2 12"; do
  set -- $T
  NAME=$1; OCPU=$2; MEM=$3

  EX=$($OCI $AUTH compute instance list -c "$COMP" --all \
    --query "length(data[?\"display-name\"=='$NAME' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
    --raw-output 2>/dev/null)
  [ "$EX" != "0" ] && continue
  [ "$OCPU" -gt "$BUDGET" ] && continue

  OUT=$($OCI $AUTH compute instance launch \
    --availability-domain "$AD" --compartment-id "$COMP" \
    --shape "VM.Standard.A1.Flex" --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEM}" \
    --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
    --display-name "$NAME" \
    --metadata "{\"ssh_authorized_keys\": \"$PUBKEY\"}" 2>&1)

  if echo "$OUT" | grep -q '"id"'; then
    BUDGET=$((BUDGET - OCPU))
    log "SUCCES : $NAME creee ($OCPU OCPU / $MEM Go) — budget restant $BUDGET"
  else
    R=$(echo "$OUT" | grep -oiE 'out of host capacity|toomanyrequests|limitexceeded' | head -1)
    log "$NAME -> ${R:-echec}"
    # Si Oracle bride, inutile d'insister sur ce passage.
    echo "$R" | grep -qi toomanyrequests && break
  fi
  sleep 5
done
