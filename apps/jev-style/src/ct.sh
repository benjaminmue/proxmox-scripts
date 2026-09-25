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
  # Architektur der Node, sonst wählt sort -V das arm64-Template (arm64 > amd64)
  local arch template
  arch=$(dpkg --print-architecture)
  template=$(pveam available --section system | awk '{print $2}' \
    | grep "^debian-13-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
  [ -n "$template" ] || msg_error "Kein debian-13-standard Template für $arch verfügbar"
  pveam list "$TSTORAGE" | grep -q "$template" || pveam download "$TSTORAGE" "$template" >/dev/null
  msg_ok "Template $template"

  local net="name=eth0,bridge=$BRIDGE,ip=$NET"
  [ -n "$VLAN" ] && net="$net,tag=$VLAN"

  msg_info "Container $CTID anlegen"
  pct status "$CTID" >/dev/null 2>&1 && msg_error "CTID $CTID ist bereits vergeben"
  pct create "$CTID" "$TSTORAGE:vztmpl/$template" \
    --hostname "$HN" --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" --net0 "$net" \
    --unprivileged 1 --features nesting=1 --onboot 1 --tags "$TAGS" \
    --description "Jev-Style-0.8B-Decision-v3, TypeSafe-kompatible API auf Port 8000. Token: /etc/jev-style/token" \
    >/dev/null || msg_error "pct create fehlgeschlagen"
  pct start "$CTID" \
    || msg_error "Container $CTID startet nicht. Details: pct start $CTID --debug; entfernen: pct destroy $CTID"
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

# @@PAYLOAD@@

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
