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

# Modell: nur Q8_0 plus Runtime-Dateien, nicht F16/Q4; fester Commit statt main.
# Pro Muster ein eigenes --include: weitere Werte nach dem ersten wertet hf als Dateinamen
# und ignoriert das Include dann komplett (GGUF fehlte so).
set --
for pattern in "$QUANT_FILE" "*.py" "*.json" "*.sh" "*.cpp" "tokenizer/*" requirements.txt LICENSE NOTICE; do
  set -- "$@" --include "$pattern"
done
"$BASE/venv/bin/hf" download "$MODEL_REPO" --revision "$MODEL_REVISION" --local-dir "$BASE/model" "$@"
[ -s "$BASE/model/$QUANT_FILE" ] || { echo "$QUANT_FILE fehlt nach dem Download" >&2; exit 1; }

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
