#!/bin/bash
# Chasse les tranches ARM Always Free depuis la VM elle-meme (service continu).
#
# Aucune cle stockee : authentification "instance principal".
#
# OPTIMISATION : la decouverte (compartiment, AD, sous-reseau, image, cle SSH)
# est faite UNE SEULE FOIS au demarrage. La boucle ne fait plus qu'un appel
# "launch" par tentative, au lieu de 7-9 appels par cycle. Sur une VM 1 Go,
# chaque appel oci coute ~15 s de demarrage Python : c'est ce qui plombait
# la cadence.
#
# Cibles (somme = 4 OCPU / 24 Go = maximum gratuit) :
#   arm-vm-1 = 1 OCPU / 6 Go
#   arm-vm-2 = 1 OCPU / 6 Go
#   arm-vm-3 = 2 OCPU / 12 Go
#
# Garde-fous anti-facturation :
#   - budget = 4 - (OCPU ARM reellement utilises), revalide toutes les 20 boucles
#   - decremente immediatement apres chaque creation reussie
#   - une cible acquise n'est plus jamais retentee

set +e

OCI=/opt/oci-grabber/venv/bin/oci
AUTH="--auth instance_principal"
MD="http://169.254.169.254/opc/v2"
HDR="Authorization: Bearer Oracle"
LOG=/var/log/oci-grabber.log
GAP=25          # secondes entre deux tentatives
BACKOFF=150     # pause si Oracle bride (TooManyRequests)

log() { echo "$(date -Is) $*" >> "$LOG"; }

# ---------- Decouverte (une seule fois, avec attente si le reseau tarde) ----------
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

log "demarrage : decouverte OK, chasse ARM active (1 tentative / ${GAP}s)"

# ---------- Budget d'OCPU ARM ----------
refresh_budget() {
  local cnt used
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
  case "$used" in ''|*[!0-9.]*) used=4 ;; esac
  BUDGET=$(awk -v u="$used" 'BEGIN{printf "%d", 4-u}')
  [ "$BUDGET" -lt 0 ] && BUDGET=0

  # Cibles deja existantes -> ne plus les tenter
  ACQUIS=""
  for T in arm-vm-1 arm-vm-2 arm-vm-3; do
    local ex
    ex=$($OCI $AUTH compute instance list -c "$COMP" --all \
      --query "length(data[?\"display-name\"=='$T' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
      --raw-output 2>/dev/null)
    [ "$ex" != "0" ] && ACQUIS="$ACQUIS $T"
  done
}

refresh_budget
log "budget initial : $BUDGET OCPU ; deja acquis :${ACQUIS:- aucun}"

# ---------- Boucle de chasse ----------
I=0
while true; do
  # Revalidation periodique contre la realite (toutes les ~20 boucles)
  if [ $((I % 20)) -eq 0 ] && [ $I -gt 0 ]; then
    refresh_budget
    log "revalidation : budget $BUDGET OCPU ; acquis :${ACQUIS:- aucun}"
  fi
  I=$((I + 1))

  if [ "$BUDGET" -le 0 ]; then
    log "quota ARM plein — plus rien a chasser. Arret du service."
    exit 0
  fi

  for T in "arm-vm-1 1 6" "arm-vm-2 1 6" "arm-vm-3 2 12"; do
    set -- $T
    NAME=$1; OCPU=$2; MEM=$3

    echo "$ACQUIS" | grep -qw "$NAME" && continue
    [ "$OCPU" -gt "$BUDGET" ] && continue

    OUT=$($OCI $AUTH compute instance launch \
      --availability-domain "$AD" --compartment-id "$COMP" \
      --shape "VM.Standard.A1.Flex" --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEM}" \
      --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
      --display-name "$NAME" \
      --metadata "{\"ssh_authorized_keys\": \"$PUBKEY\"}" 2>&1)

    if echo "$OUT" | grep -q '"id"'; then
      BUDGET=$((BUDGET - OCPU))
      ACQUIS="$ACQUIS $NAME"
      log "*** SUCCES *** $NAME creee ($OCPU OCPU / $MEM Go) — budget restant $BUDGET"
    else
      R=$(echo "$OUT" | grep -oiE 'out of host capacity|toomanyrequests|limitexceeded' | head -1)
      log "$NAME -> ${R:-echec}"
      if echo "$R" | grep -qi toomanyrequests; then
        log "bride par Oracle -> pause ${BACKOFF}s"
        sleep "$BACKOFF"
        continue
      fi
    fi
    sleep "$GAP"
  done
done
