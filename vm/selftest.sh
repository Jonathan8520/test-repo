#!/bin/bash
# Verifie si le bot de scraping Xbox/Gamepass peut tourner sur CETTE VM.
#
# Ecrit pour etre lance a la main en SSH : l'agent Oracle (Run Command) ne
# consomme pas les commandes sur amd-vm (teste le 31/08, bloque en ACCEPTED),
# donc le pilotage a distance depuis GitHub Actions n'est pas possible.
#
#   curl -sL https://raw.githubusercontent.com/Jonathan8520/test-repo/claude/oci-scraping-bot-migration-xuh9d1/vm/selftest.sh -o selftest.sh
#   sudo bash selftest.sh
#
# Options (cumulables) :
#   --with-x        recherche X REELLE avec tes cookies (lit un .env, voir plus bas)
#   --with-discord  envoie UNE notification Discord de test, clairement etiquetee
#   --cleanup       supprime le venv de test et sort
#
# Les phases 1 a 3 ne demandent AUCUN secret.
#
# Pour --with-x / --with-discord, cree d'abord /opt/gamepass-selftest/.env :
#   X_AUTH_TOKEN=...
#   X_CT0=...
#   DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
# (ce fichier ne quitte jamais la VM ; il n'est ni affiche ni envoye nulle part)

set -u

DIR=/opt/gamepass-selftest
VENV=$DIR/venv
WITH_X=0
WITH_DISCORD=0

for a in "$@"; do
  case "$a" in
    --with-x)       WITH_X=1 ;;
    --with-discord) WITH_DISCORD=1 ;;
    --cleanup)      rm -rf "$DIR" && echo "$DIR supprime." && df -h / | tail -1 && exit 0 ;;
    *) echo "Option inconnue : $a" ; exit 2 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "A lancer avec sudo : sudo bash selftest.sh"
  exit 1
fi

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
ko()   { printf '  \033[31m✘\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
titre(){ printf '\n\033[1m══ %s ══\033[0m\n' "$*"; }

VERDICT_RAM=0; VERDICT_NET=0; VERDICT_DEPS=0; VERDICT_X=-1; VERDICT_DISCORD=-1

# ─────────────────────────────── 1. RECON ───────────────────────────────
titre "1/5  MACHINE"
. /etc/os-release 2>/dev/null && echo "  OS        : $PRETTY_NAME ($(uname -m))"
echo "  Noyau     : $(uname -r)"
echo "  Uptime    : $(uptime -p 2>/dev/null || uptime)"
echo
free -m | head -2 | sed 's/^/  /'
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_DISPO=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
echo
df -h / | tail -1 | sed 's/^/  /'
DISK_DISPO=$(df -m / | awk 'NR==2{print $4}')
echo

if [ "${MEM_DISPO:-0}" -ge 300 ]; then
  ok "RAM disponible : ${MEM_DISPO} Mo (le bot en demande ~80-150)"
  VERDICT_RAM=1
elif [ "${SWAP_TOTAL:-0}" -ge 512 ]; then
  warn "RAM disponible faible (${MEM_DISPO} Mo) mais swap present (${SWAP_TOTAL} Mo)"
  VERDICT_RAM=1
else
  ko "RAM disponible ${MEM_DISPO} Mo et pas de swap — ajouter un swapfile"
fi
[ "${SWAP_TOTAL:-0}" -eq 0 ] && warn "Aucun swap. Conseille sur 1 Go de RAM (voir vm/install.sh)"
[ "${DISK_DISPO:-0}" -ge 1024 ] && ok "Disque libre : $((DISK_DISPO/1024)) Go" \
                                || ko "Disque libre insuffisant : ${DISK_DISPO} Mo"

echo
echo "  Services non-systeme actifs :"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | grep -viE "systemd|dbus|cron|rsyslog|snapd|polkit|udev|getty|unattended|multipathd|irqbalance|chrony|iscsi|ssh" \
  | awk '{print "    " $1}' | head -15
echo "  oci-grabber  : $(systemctl is-active oci-grabber 2>/dev/null || echo absent)"
echo "  agent Oracle : $(systemctl is-active oracle-cloud-agent 2>/dev/null || echo 'absent/inactif')"
echo "  (agent inactif = Run Command muet ; sans incidence sur le bot)"

# ─────────────────────────────── 2. RESEAU ──────────────────────────────
titre "2/5  RESEAU SORTANT"
echo "  IP publique vue de l'exterieur : $(curl -s -m 15 https://api.ipify.org 2>/dev/null || echo '(injoignable)')"
echo
NET_KO=0
# codeberg.org sert twikit (installe par git+https) : sans lui, l'installation
# du bot echoue, meme si tout le reste repond.
for H in https://x.com/robots.txt https://api.x.com https://pbs.twimg.com \
         https://discord.com/api/v10/gateway https://api.puter.com \
         https://pypi.org/simple/ https://codeberg.org/phin/twikit; do
  C=$(curl -s -o /dev/null -w "%{http_code}" -m 20 "$H" 2>/dev/null)
  T=$(curl -s -o /dev/null -w "%{time_total}" -m 20 "$H" 2>/dev/null)
  if [ "$C" = "000" ]; then
    printf '  \033[31m✘\033[0m %-42s injoignable\n' "$H"
    NET_KO=$((NET_KO+1))
  else
    printf '  \033[32m✔\033[0m %-42s HTTP %s  (%ss)\n' "$H" "$C" "$T"
  fi
done
[ "$NET_KO" -eq 0 ] && VERDICT_NET=1 || ko "$NET_KO hote(s) injoignable(s)"

# ─────────────────────────────── 3. DEPS ────────────────────────────────
titre "3/5  DEPENDANCES DU BOT"
mkdir -p "$DIR" && cd "$DIR" || exit 1

command -v git >/dev/null 2>&1 || {
  echo "  git absent, installation…"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null 2>&1
}
echo "  git       : $(git --version 2>&1 | head -1)"
echo "  python3   : $(python3 --version 2>&1)"

if [ ! -x "$VENV/bin/python" ]; then
  if ! python3 -m venv "$VENV" >/tmp/venv.log 2>&1; then
    echo "  venv indisponible, installation de python3-venv…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null 2>&1
    python3 -m venv "$VENV" >/tmp/venv.log 2>&1 || { ko "venv impossible :"; tail -5 /tmp/venv.log; exit 1; }
  fi
fi
ok "venv pret"

echo "  Installation de twikit / httpx / Pillow / python-dotenv (patiente, 1 cœur)…"
echo "  (twikit vient de codeberg.org : cet hote doit etre joignable)"
T0=$(date +%s)
DEPS_OK=0
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1
if "$VENV/bin/pip" install -q httpx Pillow python-dotenv \
     "twikit @ git+https://codeberg.org/phin/twikit" >/tmp/pip.log 2>&1; then
  ok "pip install reussi en $(( $(date +%s) - T0 )) s"
  DEPS_OK=1
else
  ko "pip install echoue :"
  tail -12 /tmp/pip.log | sed 's/^/    /'
fi

if [ "$DEPS_OK" = "1" ]; then

command -v tesseract >/dev/null 2>&1 || {
  echo "  tesseract absent, installation (filet de secours OCR)…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tesseract-ocr >/dev/null 2>&1
}
echo "  tesseract : $(tesseract --version 2>&1 | head -1 || echo absent)"

# Meme correctif que patch_twikit.py : sans lui, twikit plante sur les tweets
# dont le champ withheld_in_countries est absent.
"$VENV/bin/python" - <<'PY'
import twikit
from pathlib import Path
OLD = "legacy['withheld_in_countries']"
NEW = "legacy.get('withheld_in_countries', [])"
for p in (Path(twikit.__file__).parent / "user.py",
          Path(twikit.__file__).parent / "guest" / "user.py"):
    if not p.exists():
        continue
    c = p.read_text(encoding="utf-8")
    if OLD in c:
        p.write_text(c.replace(OLD, NEW), encoding="utf-8")
        print(f"  patch twikit applique : {p.parent.name}/{p.name}")
    elif NEW in c:
        print(f"  patch twikit deja present : {p.parent.name}/{p.name}")
PY

"$VENV/bin/python" - <<'PY'
import resource, twikit, httpx, PIL
twikit.Client("fr-FR")
rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024
print(f"  imports OK — httpx {httpx.__version__}, Pillow {PIL.__version__}")
print(f"  empreinte memoire d'un client twikit : {rss} Mo")
PY
[ $? -eq 0 ] && VERDICT_DEPS=1 || ko "les imports echouent"
echo "  place occupee : $(du -sh "$DIR" 2>/dev/null | cut -f1)"

fi   # fin du bloc conditionne par DEPS_OK

# Sans dependances, les phases 4 et 5 n'ont plus de sens.
if [ "$DEPS_OK" != "1" ]; then
  WITH_X=0
  WITH_DISCORD=0
fi

# ────────────────────────── 4. RECHERCHE X REELLE ───────────────────────
if [ "$WITH_X" = "1" ]; then
  titre "4/5  RECHERCHE X REELLE (depuis cette IP)"
  if [ ! -f "$DIR/.env" ]; then
    ko "$DIR/.env absent — cree-le avec X_AUTH_TOKEN et X_CT0 (voir l'entete)"
    VERDICT_X=0
  else
    "$VENV/bin/python" - <<'PY'
import asyncio, os, sys
from dotenv import load_dotenv
from twikit import Client
load_dotenv("/opt/gamepass-selftest/.env")
tok, ct0 = os.environ.get("X_AUTH_TOKEN"), os.environ.get("X_CT0")
if not tok or not ct0:
    print("  \033[31m✘\033[0m X_AUTH_TOKEN / X_CT0 manquants dans le .env"); sys.exit(1)

async def main():
    c = Client("fr-FR")
    c.set_cookies({"auth_token": tok, "ct0": ct0})
    total = 0
    for q in ("code gamepass", "code game pass"):
        try:
            tw = await c.search_tweet(q, product="Latest", count=20)
        except Exception as e:
            print(f"  \033[31m✘\033[0m '{q}' -> {type(e).__name__}: {str(e)[:180]}")
            return 1
        print(f"  \033[32m✔\033[0m '{q}' -> {len(tw)} tweets")
        for t in tw[:3]:
            txt = (t.text or "").replace("\n", " ")[:70]
            print(f"      @{t.user.screen_name}: {txt}…")
        total += len(tw)
    if total == 0:
        print("  \033[33m!\033[0m 0 tweet : cookies acceptes mais aucun resultat (rare)")
        return 1
    print(f"  \033[32m✔\033[0m {total} tweets au total — les cookies fonctionnent depuis cette IP")
    return 0

sys.exit(asyncio.run(main()))
PY
    [ $? -eq 0 ] && VERDICT_X=1 || VERDICT_X=0
  fi
fi

# ─────────────────────────── 5. NOTIF DISCORD ───────────────────────────
if [ "$WITH_DISCORD" = "1" ]; then
  titre "5/5  NOTIFICATION DISCORD DE TEST"
  if [ ! -f "$DIR/.env" ]; then
    ko "$DIR/.env absent — DISCORD_WEBHOOK requis"
    VERDICT_DISCORD=0
  else
    "$VENV/bin/python" - <<'PY'
import os, sys, socket, httpx
from dotenv import load_dotenv
load_dotenv("/opt/gamepass-selftest/.env")
wh = os.environ.get("DISCORD_WEBHOOK")
if not wh:
    print("  \033[31m✘\033[0m DISCORD_WEBHOOK manquant dans le .env"); sys.exit(1)
ip = httpx.get("https://api.ipify.org", timeout=15).text
msg = ("🧪 **Test de migration OCI** — ceci n'est pas un vrai code.\n"
       f"Emis depuis la VM `{socket.gethostname()}` (IP `{ip}`).\n"
       "Si tu vois ce message, le chemin Discord fonctionne depuis la VM.")
r = httpx.post(wh, json={"content": msg}, timeout=30)
if r.status_code in (200, 204):
    print("  \033[32m✔\033[0m Discord a accepte le message (HTTP %s)" % r.status_code)
    sys.exit(0)
print("  \033[31m✘\033[0m Discord HTTP %s : %s" % (r.status_code, r.text[:200]))
sys.exit(1)
PY
    [ $? -eq 0 ] && VERDICT_DISCORD=1 || VERDICT_DISCORD=0
  fi
fi

# ─────────────────────────────── VERDICT ────────────────────────────────
titre "VERDICT"
v() { [ "$2" = "1" ] && ok "$1" || { [ "$2" = "-1" ] && echo "  – $1 : non teste" || ko "$1"; }; }
v "Ressources machine (RAM/disque)" "$VERDICT_RAM"
v "Reseau sortant vers les 6 hotes" "$VERDICT_NET"
v "Dependances Python installables" "$VERDICT_DEPS"
v "Recherche X authentifiee"        "$VERDICT_X"
v "Notification Discord"            "$VERDICT_DISCORD"
echo
if [ "$VERDICT_RAM" = "1" ] && [ "$VERDICT_NET" = "1" ] && [ "$VERDICT_DEPS" = "1" ]; then
  if [ "$VERDICT_X" = "1" ]; then
    printf '\033[1;32m  => Le bot peut tourner sur cette VM, recherche X comprise.\033[0m\n'
  elif [ "$VERDICT_X" = "0" ]; then
    printf '\033[1;31m  => Environnement bon, mais la recherche X echoue depuis cette IP.\033[0m\n'
    echo "     C'est le point bloquant : cookies expires, ou IP datacenter filtree par X."
  else
    printf '\033[1;33m  => Environnement bon. Relance avec --with-x pour le test decisif.\033[0m\n'
  fi
else
  printf '\033[1;31m  => Environnement insuffisant, voir les lignes rouges ci-dessus.\033[0m\n'
fi
echo
echo "  Nettoyage : sudo bash selftest.sh --cleanup"
