#!/bin/bash
# Chasse les VM ARM Always Free depuis la VM elle-meme (service continu).
#
# Aucune cle stockee : authentification "instance principal".
#
# QUOTA REEL DE CE COMPTE (verifie par l'API, pas par la doc generale) :
#   standard-a1-core-count   = 2
#   standard-a1-memory-count = 12
# Soit 2 cœurs / 12 Go au total pour l'ARM — et NON 4/24 comme l'annonce le
# programme Always Free generique. Pour reverifier un jour :
#   oci limits value list --compartment-id <tenancy> --service-name compute \
#     --query 'data[?contains(name, `a1`)]' --output table
#
# STOCKAGE : 200 Go au total, 94 deja pris par les 2 VM AMD (47 Go chacune).
# Il reste ~106 Go, soit 2 VM supplementaires maximum.
#
# STRATEGIE (rotation) : a chaque cycle on tente d'abord la grosse (2/12) ;
# si elle ne passe pas, on tente la petite (1/6). On prend ce qui se libere
# en premier, quitte a finir avec une seule petite VM.
#   - budget 2 cœurs libres -> arm-vm-1 en 2/12, sinon arm-vm-1 en 1/6
#   - arm-vm-1 deja prise en 1/6 -> arm-vm-2 en 1/6 (complete le quota)
#
# Depasser une limite de service ne facture RIEN : Oracle refuse la demande.

set +e

OCI=/opt/oci-grabber/venv/bin/oci
AUTH="--auth instance_principal"
MD="http://169.254.169.254/opc/v2"
HDR="Authorization: Bearer Oracle"
LOG=/var/log/oci-grabber.log
MAXCORES=2      # quota ARM reel de ce compte
GAP=25
BACKOFF=150

log() { echo "$(date -Is) $*" >> "$LOG"; }

# ---------- Decouverte (une seule fois) ----------
while true; do
  INST=$(curl -s -m 10 -H "$HDR" "$MD/instance/")
  COMP=$(echo "$INST" | jq -r .compartmentId 2>/dev/null)
  AD=$(echo "$INST"   | jq -r .availabilityDomain 2>/dev/null)
  VNIC=$(curl -s -m 10 -H "$HDR" "$MD/vnics/" | jq -r '.[0].vnicId' 2>/dev/null)
  if [ -n "$COMP" ] && [ "$COMP" != "null" ] && [ -n "$VNIC" ] && [ "$VNIC" != "null" ]; then
    break
  fi
  log "attente des metadonnees d'instance…"
  sleep 20
done

SUBNET=$($OCI $AUTH network vnic get --vnic-id "$VNIC" --query 'data."subnet-id"' --raw-output 2>/dev/null)
[ -z "$SUBNET" ] && { log "ERREUR: sous-reseau introuvable (politique IAM ?)"; exit 1; }

PUBKEY=$(head -1 /home/ubuntu/.ssh/authorized_keys 2>/dev/null)
[ -z "$PUBKEY" ] && { log "ERREUR: cle SSH publique introuvable"; exit 1; }

IMG=$($OCI $AUTH compute image list -c "$COMP" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED \
  --query 'data[0].id' --raw-output 2>/dev/null)
[ -z "$IMG" ] && { log "ERREUR: image ARM introuvable"; exit 1; }

log "demarrage : decouverte OK — quota ARM $MAXCORES cœurs, rotation 2/12 puis 1/6"

# ---------- Etat reel (budget + VM deja obtenues) ----------
refresh_state() {
  local cnt used t ex
  cnt=$($OCI $AUTH compute instance list -c "$COMP" --all \
    --query "length(data[?\"shape\"=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
    --raw-output 2>/dev/null)
  if [ "$cnt" = "0" ]; then
    used=0
  else
    used=$($OCI $AUTH compute instance list -c "$COMP" --all \
      --query "sum(data[?\"shape\"=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'].\"shape-config\".ocpus)" \
      --raw-output 2>/dev/null)
  fi
  case "$used" in ''|*[!0-9.]*) used=$MAXCORES ;; esac
  BUDGET=$(awk -v u="$used" -v m="$MAXCORES" 'BEGIN{printf "%d", m-u}')
  [ "$BUDGET" -lt 0 ] && BUDGET=0

  ACQUIS=""
  for t in arm-vm-1 arm-vm-2; do
    ex=$($OCI $AUTH compute instance list -c "$COMP" --all \
      --query "length(data[?\"display-name\"=='$t' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
      --raw-output 2>/dev/null)
    [ "$ex" != "0" ] && ACQUIS="$ACQUIS $t"
  done
}

has() { echo "$ACQUIS" | grep -qw "$1"; }

tenter() {
  local NAME=$1 OCPU=$2 MEM=$3 OUT R
  OUT=$($OCI $AUTH compute instance launch \
    --availability-domain "$AD" --compartment-id "$COMP" \
    --shape "VM.Standard.A1.Flex" --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEM}" \
    --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
    --display-name "$NAME" \
    --metadata "{\"ssh_authorized_keys\": \"$PUBKEY\"}" 2>&1)

  if echo "$OUT" | grep -q '"id"'; then
    BUDGET=$((BUDGET - OCPU))
    ACQUIS="$ACQUIS $NAME"
    log "*** SUCCES *** $NAME creee ($OCPU cœur(s) / $MEM Go) — budget restant $BUDGET"
    return 0
  fi
  R=$(echo "$OUT" | grep -oiE 'out of host capacity|toomanyrequests|limitexceeded' | head -1)
  log "$NAME ${OCPU}/${MEM} -> ${R:-echec}"
  if echo "$R" | grep -qi toomanyrequests; then
    log "bride par Oracle -> pause ${BACKOFF}s"
    sleep "$BACKOFF"
    return 2
  fi
  return 1
}

refresh_state
log "budget initial : $BUDGET cœur(s) ; deja acquis :${ACQUIS:- aucun}"

# ---------- Boucle de chasse ----------
I=0
while true; do
  if [ $((I % 20)) -eq 0 ] && [ $I -gt 0 ]; then
    refresh_state
    log "revalidation : budget $BUDGET ; acquis :${ACQUIS:- aucun}"
  fi
  I=$((I + 1))

  if [ "$BUDGET" -le 0 ]; then
    log "quota ARM plein — plus rien a chasser. Arret du service."
    exit 0
  fi

  if ! has arm-vm-1; then
    # Rotation : la grosse d'abord, la petite ensuite.
    if [ "$BUDGET" -ge 2 ]; then
      tenter arm-vm-1 2 12 && continue
      sleep "$GAP"
    fi
    has arm-vm-1 || { tenter arm-vm-1 1 6; sleep "$GAP"; }
  elif ! has arm-vm-2 && [ "$BUDGET" -ge 1 ]; then
    tenter arm-vm-2 1 6
    sleep "$GAP"
  else
    sleep "$GAP"
  fi
done
