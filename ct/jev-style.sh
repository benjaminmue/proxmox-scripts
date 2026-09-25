#!/usr/bin/env bash
# jev-style.sh - Proxmox-Helper im Stil von community-scripts.org
# Legt einen Debian-13-LXC an und installiert darin Jev-Style-0.8B-Decision-v3 (GGUF, CPU)
# als TypeSafe-kompatible API (POST /v1/systemone).
# Aufruf als root auf einer PVE-Node:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/benjaminmue/proxmox-scripts/main/ct/jev-style.sh)"
# Generiert aus apps/jev-style/src/ via build.sh - dort ändern, nicht in ct/jev-style.sh.
set -euo pipefail

APP="Jev-Style"
TAGS="ai;jev"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

YW=$'\e[33m'; GN=$'\e[32m'; RD=$'\e[31m'; BL=$'\e[36m'; CL=$'\e[0m'

msg_info()  { printf ' %s...%s %s\n' "$YW" "$CL" "$1"; }
msg_ok()    { printf ' %s✔%s  %s\n' "$GN" "$CL" "$1"; }
msg_error() { printf ' %s✖%s  %s\n' "$RD" "$CL" "$1" >&2; exit 1; }

header() {
  clear
  cat <<'EOF'
       __                _____ __        __
      / /__ _   __      / ___// /___  __/ /__
 __  / / _ \ | / /_____ \__ \/ __/ / / / / _ \
/ /_/ /  __/ |/ /_____/___/ / /_/ /_/ / /  __/
\____/\___/|___/     /____/\__/\__, /_/\___/
                              /____/
      System One Decisions  |  0.8B  |  CPU
EOF
  echo
}

# Läuft nur als root auf einer Proxmox-Node mit whiptail.
check_host() {
  [ "$(id -u)" -eq 0 ] || msg_error "Als root ausführen"
  command -v pct >/dev/null 2>&1 || msg_error "Keine Proxmox-Node (pct fehlt)"
  command -v whiptail >/dev/null 2>&1 || msg_error "whiptail fehlt (apt install whiptail)"
}

# Erster Storage, der den angegebenen Inhaltstyp aufnehmen kann.
first_storage() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}

default_settings() {
  CTID=$(pvesh get /cluster/nextid)
  HN="jev-style"
  CORES=4
  RAM=6144
  SWAP=512
  DISK=12
  STORAGE=$(first_storage rootdir)
  TSTORAGE=$(first_storage vztmpl)
  BRIDGE="vmbr0"
  VLAN=""
  NET="dhcp"
  [ -n "$STORAGE" ] || msg_error "Kein Storage für Container gefunden"
  [ -n "$TSTORAGE" ] || msg_error "Kein Storage für Templates gefunden"
}

# Einzelnes Eingabefeld; Abbrechen beendet das Script.
ask() {
  whiptail --title "$APP LXC" --inputbox "$1" 9 60 "$2" 3>&1 1>&2 2>&3 || msg_error "Abgebrochen"
}

# Auswahl aus den aktiven Storages mit passendem Inhaltstyp.
ask_storage() {
  local content=$1 current=$2 items=()
  while read -r name type _; do
    items+=("$name" "$type")
  done < <(pvesm status -content "$content" | awk 'NR>1 && $3=="active" {print $1, $2}')
  whiptail --title "$APP LXC" --default-item "$current" --menu "Storage für $content" 16 60 6 \
    "${items[@]}" 3>&1 1>&2 2>&3 || msg_error "Abgebrochen"
}

advanced_settings() {
  CTID=$(ask "Container-ID" "$CTID")
  HN=$(ask "Hostname" "$HN")
  CORES=$(ask "CPU-Kerne" "$CORES")
  RAM=$(ask "RAM in MB (min. 2048)" "$RAM")
  DISK=$(ask "Disk in GB (min. 8)" "$DISK")
  STORAGE=$(ask_storage rootdir "$STORAGE")
  BRIDGE=$(ask "Bridge" "$BRIDGE")
  VLAN=$(ask "VLAN-Tag (leer = keiner)" "$VLAN")
  NET=$(ask "IP: dhcp oder CIDR,gw=... (z.B. 192.168.1.95/24,gw=192.168.1.1)" "$NET")
}

choose_mode() {
  local summary="CTID $CTID | $HN | ${CORES} vCPU | $((RAM / 1024)) GB RAM | ${DISK} GB auf $STORAGE\nNetz $BRIDGE${VLAN:+ VLAN $VLAN} | IP $NET"
  if whiptail --title "$APP LXC" --yes-button "Standard" --no-button "Erweitert" \
       --yesno "Standard-Einstellungen verwenden?\n\n$summary" 12 70; then
    return
  fi
  advanced_settings
}

confirm() {
  whiptail --title "$APP LXC" --yesno "Container $CTID ($HN) jetzt anlegen und installieren?\nDauer rund 10 bis 20 Minuten (llama.cpp wird kompiliert)." 10 70 \
    || msg_error "Abgebrochen"
}

create_ct() {
  msg_info "Debian-13-Template prüfen"
  pveam update >/dev/null
  local template
  template=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard' | sort -V | tail -n 1)
  [ -n "$template" ] || msg_error "Kein debian-13-standard Template verfügbar"
  pveam list "$TSTORAGE" | grep -q "$template" || pveam download "$TSTORAGE" "$template" >/dev/null
  msg_ok "Template $template"

  local net="name=eth0,bridge=$BRIDGE,ip=$NET"
  [ -n "$VLAN" ] && net="$net,tag=$VLAN"

  msg_info "Container $CTID anlegen"
  pct create "$CTID" "$TSTORAGE:vztmpl/$template" \
    --hostname "$HN" --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" --net0 "$net" \
    --unprivileged 1 --features nesting=1 --onboot 1 --tags "$TAGS" \
    --description "Jev-Style-0.8B-Decision-v3, TypeSafe-kompatible API auf Port 8000. Token: /etc/jev-style/token" \
    >/dev/null
  pct start "$CTID"
  msg_ok "Container $CTID gestartet"

  msg_info "Warte auf Netzwerk im Container"
  local i=0
  until pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 45 ] && msg_error "Container hat kein Netz (Bridge/VLAN/IP prüfen)"
    sleep 2
  done
  msg_ok "Netzwerk bereit"
}

install_app() {
  write_payload
  pct push "$CTID" "$WORK/install.sh" /root/install.sh
  pct push "$CTID" "$WORK/server.py" /root/server.py
  pct push "$CTID" "$WORK/jev-style.service" /root/jev-style.service
  msg_info "Installation im Container (Ausgabe folgt)"
  pct exec "$CTID" -- bash /root/install.sh || msg_error "Installation fehlgeschlagen, Container $CTID bleibt für die Analyse stehen"
  pct exec "$CTID" -- rm -f /root/install.sh /root/server.py /root/jev-style.service
  msg_ok "Installation abgeschlossen"
}

summary() {
  local ip
  ip=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
  echo
  msg_ok "$APP läuft in Container $CTID"
  printf '   API:    %shttp://%s:8000/v1/systemone%s\n' "$BL" "$ip" "$CL"
  printf '   Health: %shttp://%s:8000/healthz%s\n' "$BL" "$ip" "$CL"
  printf '   Token:  pct exec %s -- cat /etc/jev-style/token\n' "$CTID"
}

# Eingebettete Dateien, generiert von apps/jev-style/build.sh
write_payload() {
  cat > "$WORK/install.sh" <<'__INSTALL_SH__'
#!/bin/sh
# 02-install.sh
# Läuft IM Container (wird von 01-pve-create-lxc.sh aufgerufen, kann auch manuell erneut laufen).
# Installiert llama.cpp (gepinnter Commit), das Jev-Style-0.8B-v3-Modell (Q8_0), den Scorer und den API-Server.
set -eu

BASE=/opt/jev-style
MODEL_REPO=chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF
MODEL_REVISION=d47cd06c9d6480f1e830f9e5d223d43cb2348aeb   # Hugging-Face-Commit vom 25.09.2026
QUANT_FILE=Jev-Style-0.8B-Decision-v3-Q8_0.gguf
# Python-Pakete gepinnt, am 25.09.2026 mit pip-audit ohne Befund geprüft
PY_PACKAGES="huggingface_hub==1.33.0 tokenizers==0.23.2 numpy==2.5.3 fastapi==0.141.1 uvicorn[standard]==0.54.0"
LLAMA_COMMIT=441df11f65ea0b6d0c72965aaf70c8241070ddcb   # laut Model Card getestet

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential cmake pkg-config libcurl4-openssl-dev git ca-certificates python3 python3-venv curl

id jevstyle >/dev/null 2>&1 || useradd --system --home "$BASE" --shell /usr/sbin/nologin jevstyle
mkdir -p "$BASE" /etc/jev-style

# Python-Umgebung
[ -d "$BASE/venv" ] || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install --upgrade pip
# shellcheck disable=SC2086  # Paketliste bewusst per Word-Splitting
"$BASE/venv/bin/pip" install $PY_PACKAGES

# Modell: nur Q8_0 plus Runtime-Dateien, nicht F16/Q4; fester Commit statt main
"$BASE/venv/bin/hf" download "$MODEL_REPO" --revision "$MODEL_REVISION" --local-dir "$BASE/model" \
  --include "$QUANT_FILE" "*.py" "*.json" "*.sh" "*.cpp" "tokenizer/*" requirements.txt LICENSE NOTICE

# llama.cpp auf dem getesteten Commit, dann den Scorer bauen (CPU)
if [ ! -d "$BASE/llama.cpp/.git" ]; then
  git clone https://github.com/ggml-org/llama.cpp "$BASE/llama.cpp"
fi
git -C "$BASE/llama.cpp" fetch --quiet origin
git -C "$BASE/llama.cpp" checkout --quiet "$LLAMA_COMMIT"
(cd "$BASE/model" && sh build_jev_score.sh "$BASE/llama.cpp")
[ -x "$BASE/model/build/jev-score" ] || { echo "jev-score wurde nicht gebaut" >&2; exit 1; }

# Server und Dienst
install -m 0644 /root/server.py "$BASE/server.py"
install -m 0644 /root/jev-style.service /etc/systemd/system/jev-style.service

# API-Token einmalig erzeugen, nur für root und den Dienst lesbar
if [ ! -s /etc/jev-style/token ]; then
  umask 077
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > /etc/jev-style/token
fi
chown root:jevstyle /etc/jev-style/token
chmod 0640 /etc/jev-style/token
chown -R jevstyle:jevstyle "$BASE"

systemctl daemon-reload
systemctl enable --now jev-style.service

# Kurzer Selbsttest
i=0
until curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "Server startet nicht, siehe: journalctl -u jev-style" >&2; exit 1; }
  sleep 2
done
curl -fsS -X POST http://127.0.0.1:8000/v1/systemone \
  -H "Authorization: Bearer $(cat /etc/jev-style/token)" -H 'content-type: application/json' \
  -d '{"state":"Die USV meldet seit 10 Minuten Batteriebetrieb, Restlaufzeit 12 Minuten.","questions":{"handeln":{"type":"noul","instructions":"Muss jemand sofort eingreifen?"}}}'
echo
echo "Installation abgeschlossen."
__INSTALL_SH__
  cat > "$WORK/server.py" <<'__SERVER_PY__'
"""TypeSafe-kompatibler System-One-Server vor Jev-Style-0.8B-Decision-v3 (GGUF, llama.cpp, CPU).

Endpunkte:
    GET  /healthz        ohne Auth, nur {"ok": true}
    POST /v1/systemone   Bearer-Token, Request/Response wie https://docs.typesafe.ai/api.md

Der Scorer ist ein einzelner JSON-lines-Prozess und nicht threadsicher, daher serialisiert ein Lock
alle Anfragen. Umgebungsvariablen: JEV_MODEL_DIR, JEV_QUANT, JEV_TOKEN_FILE, JEV_THREADS, JEV_MAX_QUESTIONS.
"""

import hmac
import json
import os
import sys
import threading
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional, Union

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

MODEL_DIR = os.environ.get("JEV_MODEL_DIR", "/opt/jev-style/model")
QUANT = os.environ.get("JEV_QUANT", "Q8_0")
TOKEN_FILE = os.environ.get("JEV_TOKEN_FILE", "/etc/jev-style/token")
_CPUS = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 2)
THREADS = int(os.environ.get("JEV_THREADS", str(_CPUS)))  # im LXC die zugeteilten Kerne, nicht die des Hosts
MAX_QUESTIONS = int(os.environ.get("JEV_MAX_QUESTIONS", "16"))
MODEL_LABEL = "jev-style-0.8b-v3-" + QUANT.lower()

sys.path.insert(0, MODEL_DIR)
from jev_style_decision_gguf import (  # noqa: E402  (Pfad erst zur Laufzeit bekannt)
    InputBudgetError,
    JevStyleDecisionGGUF,
    QuestionError,
)

_engine: Optional[JevStyleDecisionGGUF] = None
_lock = threading.Lock()


def _load_token() -> str:
    """Liest das API-Token; ohne Token startet der Server nicht."""
    with open(TOKEN_FILE, encoding="utf-8") as fh:
        token = fh.read().strip()
    if not token:
        raise RuntimeError(f"Leeres Token in {TOKEN_FILE}")
    return token


API_TOKEN = _load_token()


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Startet den Scorer-Prozess einmal beim Hochfahren und beendet ihn sauber."""
    global _engine
    _engine = JevStyleDecisionGGUF(MODEL_DIR, quant=QUANT, n_gpu_layers=0, threads=THREADS, verify=True)
    try:
        yield
    finally:
        _engine.close()


app = FastAPI(title="Jev-Style System One", docs_url=None, redoc_url=None, lifespan=lifespan)


class Question(BaseModel):
    """Eine typisierte Frage im TypeSafe-Format."""

    type: str = Field(pattern="^(noul|choice|score)$")
    instructions: Union[str, Dict[str, Any], list]
    criteria: Optional[Union[Dict[str, Optional[str]], list]] = None


class SystemOneRequest(BaseModel):
    """Request-Body von POST /v1/systemone."""

    state: Union[str, Dict[str, Any], list]
    model: Optional[str] = None
    questions: Dict[str, Question]


def require_token(authorization: str = Header(default="")) -> None:
    """Prüft den Bearer-Token zeitkonstant."""
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(value.strip(), API_TOKEN):
        raise HTTPException(status_code=401, detail="invalid or missing API key")


def to_runtime_question(q: Question) -> dict:
    """Übersetzt eine TypeSafe-Frage in das Runtime-Format {"t", "ins", "crit"}."""
    ins = q.instructions if isinstance(q.instructions, str) else json.dumps(q.instructions, ensure_ascii=False)
    crit = q.criteria
    if q.type == "choice" and isinstance(crit, list):
        crit = {str(o): None for o in crit}
    return {"t": q.type, "ins": ins, "crit": crit}


def to_answer(qtype: str, crit: Any, result: dict) -> dict:
    """Formt ein Runtime-Ergebnis in die TypeSafe-Antwortstruktur um.

    confidence = entropy_concentration der Runtime (0 = gleichverteilt, 1 = eindeutig).
    score = erwarteter Level-Index (0 .. n-1), kann zwischen zwei Stufen liegen.
    """
    probs = result["probabilities"]
    if qtype == "noul":
        return {"type": "noul", "noul": probs["true"]}
    if qtype == "choice":
        return {"type": "choice", "choice": result["answer"], "probabilities": probs,
                "confidence": result["entropy_concentration"]}
    expected = sum(int(level) * p for level, p in probs.items())
    return {"type": "score", "score": expected, "legend": crit, "probabilities": probs,
            "confidence": result["entropy_concentration"]}


@app.get("/healthz")
def healthz() -> dict:
    """Lebenszeichen ohne Details."""
    return {"ok": _engine is not None}


@app.post("/v1/systemone", dependencies=[Depends(require_token)])
def system_one(req: SystemOneRequest) -> dict:
    """Beantwortet alle Fragen zu einem State in einem Scorer-Aufruf."""
    if not req.questions:
        raise HTTPException(status_code=422, detail="questions must not be empty")
    if len(req.questions) > MAX_QUESTIONS:
        raise HTTPException(status_code=422, detail=f"at most {MAX_QUESTIONS} questions per request")

    names = list(req.questions)
    runtime_qs = [to_runtime_question(req.questions[n]) for n in names]
    try:
        with _lock:
            results = _engine.decide_many(req.state, runtime_qs)
    except (InputBudgetError, QuestionError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from None

    answers = {n: to_answer(q["t"], q["crit"], r) for n, q, r in zip(names, runtime_qs, results)}
    input_tokens = max((r.get("input_tokens", 0) for r in results), default=0)
    return {"model": MODEL_LABEL, "answers": answers,
            "usage": {"input_tokens": input_tokens, "output_tokens": 0}}
__SERVER_PY__
  cat > "$WORK/jev-style.service" <<'__UNIT__'
[Unit]
Description=Jev-Style System One API (TypeSafe-kompatibel)
After=network-online.target
Wants=network-online.target

[Service]
User=jevstyle
Group=jevstyle
WorkingDirectory=/opt/jev-style
Environment=JEV_MODEL_DIR=/opt/jev-style/model
Environment=JEV_QUANT=Q8_0
Environment=JEV_TOKEN_FILE=/etc/jev-style/token
ExecStart=/opt/jev-style/venv/bin/uvicorn server:app --host 0.0.0.0 --port 8000 --workers 1
Restart=on-failure
RestartSec=5
MemoryMax=5G
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/opt/jev-style /etc/jev-style

[Install]
WantedBy=multi-user.target
__UNIT__
}

main() {
  header
  check_host
  default_settings
  choose_mode
  confirm
  create_ct
  install_app
  summary
}

main "$@"
