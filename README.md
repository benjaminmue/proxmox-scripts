# proxmox-scripts

Eigene Proxmox-VE-Helper im Stil von [community-scripts.org](https://community-scripts.org/): ein Befehl auf der PVE-Node legt einen LXC-Container an und installiert die Anwendung darin. Die Scripts sind eigenständig und laden kein fremdes Framework nach.

## Scripts

| Script | Zweck | Ressourcen (Standard) |
|---|---|---|
| [`ct/jev-style.sh`](ct/jev-style.sh) | System-One-Entscheidungsmodell Jev-Style-0.8B-v3 als TypeSafe-kompatible API | 4 vCPU, 6 GB RAM, 12 GB Disk |

## Aufruf

Als `root` in der Shell einer Proxmox-Node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/benjaminmue/proxmox-scripts/main/ct/jev-style.sh)"
```

Ein Dialog fragt nach Standard- oder erweiterten Einstellungen (CTID, Ressourcen, Storage, Bridge, VLAN, IP). Wer das Script vor dem Ausführen lesen will:

```bash
curl -fsSL -o jev-style.sh https://raw.githubusercontent.com/benjaminmue/proxmox-scripts/main/ct/jev-style.sh
less jev-style.sh && bash jev-style.sh
```

## Aufbau

```
ct/<app>.sh            ausführbares Script (generiert, nicht direkt bearbeiten)
apps/<app>/src/        Quellen: ct.sh (Host-Teil), install.sh (im Container), weitere Dateien
apps/<app>/build.sh    bettet die Quellen in ct/<app>.sh ein
apps/<app>/tests/      Tests
```

Nach Änderungen in `apps/<app>/src/`: `sh apps/<app>/build.sh`. Die CI bricht ab, wenn `ct/` nicht zum Quellstand passt.

## Apps

- [Jev-Style](apps/jev-style/README.md)

## Lizenz

Scripts unter MIT. Die installierten Modelle und Programme haben eigene Lizenzen, siehe README der jeweiligen App.
