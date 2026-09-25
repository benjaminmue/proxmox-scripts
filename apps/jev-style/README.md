# Jev-Style LXC

Installiert [Jev-Style-0.8B-Decision-v3](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF) (GGUF, Q8_0, 0.81 GB) in einem Debian-13-LXC und stellt es als HTTP-API mit dem Request-Format von TypeSafe System One bereit. Läuft ohne GPU auf der CPU.

Das Modell erzeugt keinen Text. Es beantwortet typisierte Fragen zu einem Eingabetext mit kalibrierten Wahrscheinlichkeiten:

| Typ | Kriterien | Antwort |
|---|---|---|
| `noul` | keine oder `{"false": "...", "true": "..."}` | `noul` = Wahrscheinlichkeit für ja |
| `choice` | `{name: beschreibung}` oder `[namen]` | `choice`, `probabilities`, `confidence` |
| `score` | Liste mit 2 bis 10 Stufen, niedrigste zuerst | `score` (erwarteter Stufenindex), `legend`, `probabilities`, `confidence` |

`confidence` ist die Entropie-Konzentration der Verteilung (0 = gleichverteilt, 1 = eindeutig). Die Werte sind nicht mit TypeSafe Jev vergleichbar.

## Installation

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/benjaminmue/proxmox-scripts/main/ct/jev-style.sh)"
```

Dauer rund 10 bis 20 Minuten, der grösste Teil ist das Kompilieren von llama.cpp. Der Container braucht Internet für apt, Hugging Face und GitHub.

## Aufruf

```bash
TOKEN=$(pct exec <CTID> -- cat /etc/jev-style/token)
curl -s http://<ct-ip>:8000/v1/systemone \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{
    "state": "Duplicati: Backup-Job Appdata seit 4 Tagen fehlgeschlagen, Ziel nicht erreichbar.",
    "questions": {
      "handeln":   {"type": "noul",   "instructions": "Muss ein Administrator etwas tun?"},
      "schwere":   {"type": "score",  "instructions": "Wie schwer wiegt die Meldung?", "criteria": ["Info", "Warnung", "Störung", "Ausfall"]},
      "kategorie": {"type": "choice", "instructions": "Welcher Bereich?", "criteria": ["netzwerk", "storage", "backup", "sicherheit"]}
    }
  }'
```

Grenzen: Eingabe bis 25'600 Tokens, Frage und Optionen bis 2'048 Tokens, höchstens 16 Fragen pro Request (`JEV_MAX_QUESTIONS`). Zu lange Eingaben ergeben HTTP 422, es wird nichts abgeschnitten.

## Sicherheit

- Jeder Request auf `/v1/systemone` braucht das Bearer-Token aus `/etc/jev-style/token` (0640, root:jevstyle). `/healthz` ist ohne Token erreichbar und gibt nur `{"ok": true}` zurück.
- Der Server hat **kein Rate Limiting** und verarbeitet Requests nacheinander. Nur im internen Netz betreiben, nicht ins Internet freigeben. Für Zugriff von aussen einen Reverse Proxy mit Rate Limit davorsetzen.
- Der Dienst läuft als Systembenutzer `jevstyle` mit `ProtectSystem=strict`, `NoNewPrivileges` und `MemoryMax=5G`.
- Modelldateien werden beim Start gegen die SHA-256-Summen aus `manifest.json` geprüft. llama.cpp ist auf den von der Model Card getesteten Commit gepinnt.
- Eingabetexte werden nicht protokolliert.

## Testen

```bash
JEV_URL=http://<ct-ip>:8000 JEV_API_TOKEN=<token> python apps/jev-style/eval/evaluate.py
```

Misst Trefferquote, Latenz und Kalibrierung gegen 40 deutsche Homelab-Meldungen (`eval/testset-homelab-de.jsonl`).

Unit-Tests für den Server (ohne Modell): `pip install fastapi httpx pytest && pytest apps/jev-style/tests`

## Verwaltung

```bash
pct exec <CTID> -- systemctl status jev-style
pct exec <CTID> -- journalctl -u jev-style -n 50
pct stop <CTID> && pct destroy <CTID>      # entfernen
```

## Lizenzen

- Scripts und Server: MIT
- Jev-Style-0.8B-Decision-v3: Apache-2.0, chaoliangUNSW. Unabhängiges Projekt, nicht verbunden mit TypeSafe AI.
- llama.cpp: MIT
