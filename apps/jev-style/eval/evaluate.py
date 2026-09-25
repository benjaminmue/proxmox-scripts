"""Misst den Jev-Style-Server gegen das deutsche Homelab-Testset.

Aufruf (Python 3.9+, keine Zusatzpakete):
    JEV_URL=http://<ct-ip>:8000 JEV_API_TOKEN=<token> python evaluate.py [testset.jsonl]

Ausgabe: Trefferquote je Frage, Latenz (Median/p90) und eine einfache Kalibrierungsprüfung
(mittlere angegebene Sicherheit gegen tatsächliche Trefferquote). Fehlklassifizierungen werden gelistet.
"""

import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

LEVELS = ["Info, nur zur Kenntnis", "Warnung, zeitnah prüfen", "Störung, Dienst beeinträchtigt",
          "Ausfall, Dienst oder Daten akut gefährdet"]
CATEGORIES = {
    "netzwerk": "WAN, LAN, VLAN, Switch, WLAN, Erreichbarkeit von Hosts",
    "storage": "Festplatten, Array, Pools, Speicherplatz, SMART",
    "container": "Docker-Container, Healthchecks, Neustarts",
    "sicherheit": "Logins, Angriffe, unbekannte Geräte, Secrets, Zugänge",
    "backup": "Sicherungsjobs und deren Ergebnis",
    "zertifikat": "TLS-Zertifikate, Ablauf von Keys und Tokens",
    "update": "Software-Updates, Releases, Builds",
    "strom": "USV, Stromversorgung, Temperatur, Lüfter",
}
QUESTIONS = {
    "handeln": {"type": "noul", "instructions": "Muss ein Administrator wegen dieser Meldung etwas tun?"},
    "schwere": {"type": "score", "instructions": "Wie schwer wiegt diese Meldung?", "criteria": LEVELS},
    "kategorie": {"type": "choice", "instructions": "Welchen Bereich betrifft die Meldung?", "criteria": CATEGORIES},
}


def call(url, token, state):
    """Sendet einen State mit allen Fragen, liefert (Antworten, Sekunden)."""
    body = json.dumps({"state": state, "questions": QUESTIONS}).encode("utf-8")
    req = urllib.request.Request(url.rstrip("/") + "/v1/systemone", data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
    return data["answers"], time.perf_counter() - start


def judge(answers, gold):
    """Vergleicht eine Antwort mit dem Soll; liefert je Frage (richtig, angegebene Sicherheit, Ist-Wert)."""
    p_true = answers["handeln"]["noul"]
    handeln = ((p_true >= 0.5) == gold["handeln"], max(p_true, 1 - p_true), p_true >= 0.5)
    score = answers["schwere"]["score"]
    schwere = (round(score) == gold["schwere"], answers["schwere"]["confidence"], round(score, 2))
    choice = answers["kategorie"]["choice"]
    kategorie = (choice == gold["kategorie"], max(answers["kategorie"]["probabilities"].values()), choice)
    return {"handeln": handeln, "schwere": schwere, "kategorie": kategorie}


def main():
    url = os.environ.get("JEV_URL", "http://127.0.0.1:8000")
    token = os.environ.get("JEV_API_TOKEN")
    if not token:
        sys.exit("JEV_API_TOKEN fehlt")
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "testset-homelab-de.jsonl")
    with open(path, encoding="utf-8") as fh:
        cases = [json.loads(line) for line in fh if line.strip()]

    stats = {q: {"ok": 0, "conf": []} for q in QUESTIONS}
    latencies, misses = [], []
    for case in cases:
        try:
            answers, secs = call(url, token, case["state"])
        except urllib.error.HTTPError as exc:
            sys.exit(f"Fall {case['id']}: HTTP {exc.code} {exc.read().decode(errors='replace')}")
        latencies.append(secs)
        for q, (ok, conf, got) in judge(answers, case["gold"]).items():
            stats[q]["ok"] += ok
            stats[q]["conf"].append(conf)
            if not ok:
                misses.append(f"  #{case['id']:>2} {q}: soll {case['gold'][q]!r}, ist {got!r}")

    n = len(cases)
    print(f"Fälle: {n}")
    for q, s in stats.items():
        acc = s["ok"] / n
        print(f"{q:<10} Treffer {acc:6.1%}   mittlere Sicherheit {statistics.mean(s['conf']):6.1%}")
    latencies.sort()
    print(f"Latenz     Median {statistics.median(latencies):.2f} s   p90 {latencies[int(0.9 * (n - 1))]:.2f} s")
    if misses:
        print("Abweichungen:")
        print("\n".join(misses))


if __name__ == "__main__":
    main()
