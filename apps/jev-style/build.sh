#!/bin/sh
# build.sh - setzt ct/jev-style.sh aus src/ zusammen (ct.sh + eingebettete install.sh, server.py, Unit).
# Aufruf aus dem Repo-Root: sh apps/jev-style/build.sh   (--check: nur prüfen, ob ct/ aktuell ist)
set -eu
cd "$(dirname "$0")"
OUT=../../ct/jev-style.sh

payload() {
  echo "# Eingebettete Dateien, generiert von apps/jev-style/build.sh"
  echo "write_payload() {"
  for pair in "install.sh:__INSTALL_SH__" "server.py:__SERVER_PY__" "jev-style.service:__UNIT__"; do
    file=${pair%%:*}; marker=${pair##*:}
    if grep -q "^$marker\$" "src/$file"; then
      echo "Marker $marker kommt in src/$file vor" >&2; exit 1
    fi
    echo "  cat > \"\$WORK/$file\" <<'$marker'"
    cat "src/$file"
    echo "$marker"
  done
  echo "}"
}

TMP=$(mktemp)
payload > "$TMP.payload"
awk -v pf="$TMP.payload" '/^# @@PAYLOAD@@$/ { while ((getline line < pf) > 0) print line; next } { print }' \
  src/ct.sh > "$TMP"
rm -f "$TMP.payload"
bash -n "$TMP"

if [ "${1:-}" = "--check" ]; then
  if cmp -s "$TMP" "$OUT"; then rm -f "$TMP"; echo "ct/jev-style.sh ist aktuell"; exit 0; fi
  rm -f "$TMP"; echo "ct/jev-style.sh ist veraltet: sh apps/jev-style/build.sh ausführen" >&2; exit 1
fi

mv "$TMP" "$OUT"
chmod +x "$OUT"
echo "ct/jev-style.sh gebaut ($(wc -l < "$OUT") Zeilen), Syntax ok"
