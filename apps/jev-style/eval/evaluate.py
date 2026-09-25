"""Misst den Jev-Style-Server gegen das deutsche Homelab-Testset, optional in mehreren Frage-Varianten.

Aufruf (Python 3.9+, keine Zusatzpakete):
    JEV_URL=http://<ct-ip>:8000 JEV_API_TOKEN=<token> python evaluate.py [--variant NAME|all] [testset.jsonl]

Varianten (gleiche Meldungen, unterschiedliche Fragestellung):
    de-frage    noul als Frage, score mit 4 Stufen (Ausgangslage)
    de-aussage  noul als Aussage, wie es die Runtime erwartet
    de-choice   handeln und schwere als choice mit beschriebenen Optionen
    en-choice   wie de-choice, Anweisungen und Optionen englisch (Meldung bleibt deutsch)

Ausgabe: Trefferquote und mittlere angegebene Sicherheit je Frage, Latenz. Bei einer einzelnen
Variante zusätzlich alle Abweichungen.
"""

import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------------------------
# Antwort-Leser: liefern (Wert im Format des Solls, angegebene Sicherheit)
# ---------------------------------------------------------------------------------------------


def read_noul(answer):
    """noul -> (bool, Sicherheit der gewählten Seite)."""
    p = answer["noul"]
    return p >= 0.5, max(p, 1 - p)


def read_score(answer):
    """score -> (gerundete Stufe, confidence)."""
    return round(answer["score"]), answer["confidence"]


def read_choice_map(mapping):
    """choice -> (mapping[Wahl], höchste Wahrscheinlichkeit)."""
    def read(answer):
        return mapping[answer["choice"]], max(answer["probabilities"].values())
    return read


def identity(keys):
    """Mapping, das jede Option auf sich selbst abbildet."""
    return {k: k for k in keys}


# ---------------------------------------------------------------------------------------------
# Fragen je Variante
# ---------------------------------------------------------------------------------------------

LEVELS_DE = ["Info, nur zur Kenntnis", "Warnung, zeitnah prüfen", "Störung, Dienst beeinträchtigt",
             "Ausfall, Dienst oder Daten akut gefährdet"]
CATEGORIES_DE = {
    "netzwerk": "WAN, LAN, VLAN, Switch, WLAN, Erreichbarkeit von Hosts",
    "storage": "Festplatten, Array, Pools, Speicherplatz, SMART",
    "container": "Docker-Container, Healthchecks, Neustarts",
    "sicherheit": "Logins, Angriffe, unbekannte Geräte, Secrets, Zugänge",
    "backup": "Sicherungsjobs und deren Ergebnis",
    "zertifikat": "TLS-Zertifikate, Ablauf von Keys und Tokens",
    "update": "Software-Updates, Releases, Builds",
    "strom": "USV, Stromversorgung, Temperatur, Lüfter",
}
CATEGORIES_EN = {
    "network": ("netzwerk", "WAN, LAN, VLAN, switch, Wi-Fi, host reachability"),
    "storage": ("storage", "disks, array, pools, free space, SMART"),
    "container": ("container", "Docker containers, health checks, restarts"),
    "security": ("sicherheit", "logins, attacks, unknown devices, leaked secrets, access"),
    "backup": ("backup", "backup jobs and their result"),
    "certificate": ("zertifikat", "TLS certificates, expiring keys and tokens"),
    "update": ("update", "software updates, releases, builds"),
    "power": ("strom", "UPS, power supply, temperature, fans"),
}

KATEGORIE_DE = {"type": "choice", "instructions": "Welchen Bereich betrifft die Meldung?", "criteria": CATEGORIES_DE}
READ_KATEGORIE_DE = read_choice_map(identity(CATEGORIES_DE))

HANDELN_CHOICE_DE = {"ja": "Ein Administrator muss etwas unternehmen: reparieren, prüfen, ersetzen, erneuern oder absichern.",
                     "nein": "Nur zur Kenntnis: alles läuft, der Vorgang war erfolgreich oder hat sich selbst erledigt."}
SCHWERE_CHOICE_DE = {"info": "Nur zur Kenntnis, kein Handlungsbedarf",
                     "warnung": "Zeitnah prüfen, noch keine Auswirkung",
                     "störung": "Ein Dienst ist beeinträchtigt oder fällt bald aus",
                     "ausfall": "Dienst ausgefallen oder Daten akut gefährdet"}
HANDELN_CHOICE_EN = {"yes": "An administrator has to act: fix, check, replace, renew or secure something.",
                     "no": "Informational only: everything works, the task succeeded or resolved itself."}
SCHWERE_CHOICE_EN = {"info": "Informational, nothing to do",
                     "warning": "Check soon, no impact yet",
                     "degraded": "A service is impaired or about to fail",
                     "outage": "Service down or data at acute risk"}

VARIANTS = {
    "de-frage": {
        "questions": {
            "handeln": {"type": "noul", "instructions": "Muss ein Administrator wegen dieser Meldung etwas tun?"},
            "schwere": {"type": "score", "instructions": "Wie schwer wiegt diese Meldung?", "criteria": LEVELS_DE},
            "kategorie": KATEGORIE_DE,
        },
        "read": {"handeln": read_noul, "schwere": read_score, "kategorie": READ_KATEGORIE_DE},
    },
    "de-aussage": {
        "questions": {
            "handeln": {"type": "noul", "instructions": "Ein Administrator muss wegen dieser Meldung etwas unternehmen.",
                        "criteria": {"false": "Nur zur Kenntnis, alles in Ordnung",
                                     "true": "Es muss etwas repariert, geprüft oder erneuert werden"}},
            "schwere": {"type": "score", "instructions": "Die Schwere dieser Meldung.", "criteria": LEVELS_DE},
            "kategorie": KATEGORIE_DE,
        },
        "read": {"handeln": read_noul, "schwere": read_score, "kategorie": READ_KATEGORIE_DE},
    },
    "de-choice": {
        "questions": {
            "handeln": {"type": "choice", "instructions": "Braucht diese Meldung eine Aktion eines Administrators?",
                        "criteria": HANDELN_CHOICE_DE},
            "schwere": {"type": "choice", "instructions": "Wie schwer wiegt diese Meldung?", "criteria": SCHWERE_CHOICE_DE},
            "kategorie": KATEGORIE_DE,
        },
        "read": {"handeln": read_choice_map({"ja": True, "nein": False}),
                 "schwere": read_choice_map({k: i for i, k in enumerate(SCHWERE_CHOICE_DE)}),
                 "kategorie": READ_KATEGORIE_DE},
    },
    "en-choice": {
        "questions": {
            "handeln": {"type": "choice", "instructions": "Does this homelab alert require action by an administrator?",
                        "criteria": HANDELN_CHOICE_EN},
            "schwere": {"type": "choice", "instructions": "How severe is this alert?", "criteria": SCHWERE_CHOICE_EN},
            "kategorie": {"type": "choice", "instructions": "Which area does this alert concern?",
                          "criteria": {k: desc for k, (_, desc) in CATEGORIES_EN.items()}},
        },
        "read": {"handeln": read_choice_map({"yes": True, "no": False}),
                 "schwere": read_choice_map({k: i for i, k in enumerate(SCHWERE_CHOICE_EN)}),
                 "kategorie": read_choice_map({k: gold for k, (gold, _) in CATEGORIES_EN.items()})},
    },
}

# ---------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------


def call(url, token, state, questions):
    """Sendet einen State mit allen Fragen, liefert (Antworten, Sekunden)."""
    body = json.dumps({"state": state, "questions": questions}).encode("utf-8")
    req = urllib.request.Request(url.rstrip("/") + "/v1/systemone", data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
    return data["answers"], time.perf_counter() - start


def run_variant(name, cases, url, token):
    """Lässt alle Fälle gegen eine Variante laufen; liefert Statistik, Latenzen und Abweichungen."""
    variant = VARIANTS[name]
    stats = {q: {"ok": 0, "conf": []} for q in variant["read"]}
    latencies, misses = [], []
    for case in cases:
        try:
            answers, secs = call(url, token, case["state"], variant["questions"])
        except urllib.error.HTTPError as exc:
            sys.exit(f"{name} Fall {case['id']}: HTTP {exc.code} {exc.read().decode(errors='replace')}")
        latencies.append(secs)
        for q, reader in variant["read"].items():
            got, conf = reader(answers[q])
            ok = got == case["gold"][q]
            stats[q]["ok"] += ok
            stats[q]["conf"].append(conf)
            if not ok:
                misses.append(f"  #{case['id']:>2} {q}: soll {case['gold'][q]!r}, ist {got!r}")
    return stats, latencies, misses


def report(name, n, stats, latencies):
    """Gibt die Zusammenfassung einer Variante aus."""
    print(f"\n== {name} ({n} Fälle)")
    for q, s in stats.items():
        print(f"{q:<10} Treffer {s['ok'] / n:6.1%}   mittlere Sicherheit {statistics.mean(s['conf']):6.1%}")
    latencies = sorted(latencies)
    print(f"Latenz     Median {statistics.median(latencies):.2f} s   p90 {latencies[int(0.9 * (n - 1))]:.2f} s")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", default="all", choices=["all", *VARIANTS])
    ap.add_argument("testset", nargs="?",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "testset-homelab-de.jsonl"))
    args = ap.parse_args()

    url = os.environ.get("JEV_URL", "http://127.0.0.1:8000")
    token = os.environ.get("JEV_API_TOKEN")
    if not token:
        sys.exit("JEV_API_TOKEN fehlt")
    with open(args.testset, encoding="utf-8") as fh:
        cases = [json.loads(line) for line in fh if line.strip()]

    names = list(VARIANTS) if args.variant == "all" else [args.variant]
    for name in names:
        stats, latencies, misses = run_variant(name, cases, url, token)
        report(name, len(cases), stats, latencies)
        if len(names) == 1 and misses:
            print("Abweichungen:")
            print("\n".join(misses))


if __name__ == "__main__":
    main()
