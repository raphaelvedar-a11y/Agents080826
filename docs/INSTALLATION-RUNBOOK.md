# Installations-Runbook

Wie die Agenten zum Kunden kommen, woran man erkennt, dass es geklappt hat, und
was zu tun ist, wenn nicht.

## Der Nachweis

Nach jeder Installation steht in `.claude/agent-install-report.json`:

```json
{
  "expected": 73,
  "verified": 73,
  "complete": true,
  "missing": [],
  "preflight_mode": "python",
  "profile_status": "angewendet"
}
```

**Nur `"complete": true` mit `verified == expected` zaehlt als erfolgreiche
Installation.** Ein Kommando, das ohne sichtbaren Fehler durchlief, ist kein
Nachweis — genau das hat den Vorfall unten so lange unbemerkt gelassen.

Ist `complete: false`, nennt `missing` die fehlenden Agenten namentlich. Diese
Liste gehoert unveraendert in jede Meldung und Eskalation.

## Wege der Installation

| Weg | Wann | Befehl |
|---|---|---|
| Automatisch | Kunde oeffnet das Repository in Claude Code | keiner, `.claude/hooks/session-start.sh` laeuft selbst |
| Manuell (Reparatur) | Hook lief nicht oder Installation unvollstaendig | `./scripts/install.sh --project` |
| Nutzerweit | Agenten sollen in allen Projekten verfuegbar sein | `./scripts/install.sh --user` |
| Windows | kein Bash vorhanden | `.\scripts\install.ps1 -Project` |
| Probelauf | erst sehen, was passieren wuerde | `./scripts/install.sh --project --dry-run` |

## Exit-Codes

| Exit | Bedeutung | Naechster Schritt |
|---|---|---|
| 0 | alle Agenten verifiziert | fertig |
| 1 | **Paket** defekt, nichts installiert | Repository neu beziehen; das ist kein Kundenfehler |
| 2 | Aufruffehler | `./scripts/install.sh --help` |
| 3 | Installation unvollstaendig | Schreibrechte auf dem Zielordner pruefen, erneut ausfuehren, fehlende Agenten melden |

## Was den Installer nicht mehr stoppt

Diese Faelle haben frueher zum Totalausfall gefuehrt und sind heute durch
`scripts/test_install.sh` als Regressionstest abgesichert:

- Der Kunde legt `config/customer.local.yaml` mit einer echten E-Mail-Adresse an
  (die README fordert genau das).
- Der Kunde legt `.mcp.json` an, um MCP einzurichten.
- Im Zielordner liegen bereits gleichnamige Dateien. Fremde Dateien werden vor
  dem Ueberschreiben als `.bak-<zeitstempel>` gesichert.
- `python3` fehlt komplett oder ist vorhanden, laesst sich aber nicht ausfuehren.
  Dann greift eine eingebaute Basispruefung — mit sichtbarer Warnung, nie still.
- Der Installer laeuft ein zweites Mal (Update oder Reparatur einer
  Teilinstallation).
- Das angegebene Profil fehlt oder ist unlesbar.
- Einzelne Zieldateien lassen sich nicht schreiben. Die uebrigen werden trotzdem
  installiert, und die fehlenden werden namentlich gemeldet.

## Zwei Pruefungen, zwei Zwecke

Das war die eigentliche Fehlerursache: Es gab nur eine Pruefung, und die stand
an der falschen Stelle.

| | `--mode preflight` | `--mode release` |
|---|---|---|
| **Fuer wen** | Kundeninstallation | Herausgeber und CI |
| **Prueft** | ist das Paket vollstaendig und konsistent? | zusaetzlich: Secrets, personenbezogene Reste, aktive Verbindungen |
| **Liest** | nur Paketdateien | nur **versionierte** Dateien |
| **Darf die Installation stoppen** | ja, wenn das Paket defekt ist | wird bei der Installation gar nicht ausgefuehrt |

Der Kern: Das Hygiene-Gate schuetzt die **Auslieferung**. Es hat vor der
Kundeninstallation nichts zu suchen, und es darf nie Dateien bewerten, die der
Kunde selbst angelegt hat.

## Regressionstest

```bash
./scripts/test_install.sh
```

Faehrt 17 Szenarien, darunter alle oben genannten Fehlerbilder, und prueft
zusaetzlich, dass das Auslieferungs-Gate weiterhin scharf ist. Laeuft auch in
der CI (`.github/workflows/install-verify.yml`) bei jedem Push und Pull Request.

Das Gate betrachtet versionierte **und** noch nicht committete, nicht ignorierte
Dateien. Sonst faellt eine Secret- oder E-Mail-Leiche in einer neu angelegten
Datei erst in der CI auf statt vor dem Commit — genau so ist es beim Bau dieses
Tests einmal passiert.

## Der Vorfall, der dazu gefuehrt hat

Bei einer Kundeninstallation wurden **0 von 73 Agenten** installiert, ohne
brauchbare Fehlermeldung.

Ursache: `scripts/install.sh` rief vor jeder Installation die
Auslieferungspruefung auf. Diese durchsuchte mit `rglob("*")` das gesamte
Arbeitsverzeichnis — auch die Dateien, die der Kunde nach Anleitung der README
selbst angelegt hatte. Eine E-Mail-Adresse in `config/customer.local.yaml`
reichte, um die Pruefung fehlschlagen zu lassen. Wegen `set -euo pipefail` brach
das Skript ab, bevor eine einzige Datei kopiert wurde.

Verschaerfend kamen dazu:

- Der Installer **verifizierte nie**, ob die Dateien angekommen waren.
- Ein belegter Zielordner fuehrte zum Abbruch statt zum Update.
- Ein fehlendes `python3` beendete das Skript mit Exit 127 **ohne jede Ausgabe**.
- Es gab keinen Regressionstest, der das haette auffangen koennen.

Alle vier Punkte sind behoben und durch Tests abgesichert.

## Wenn die Agentenzahl sich aendert

Die Zahl 73 steht an mehreren Stellen. Wird eine Agentendatei ergaenzt oder
entfernt, muessen diese gemeinsam angepasst werden:

- `agents/` (die Datei selbst)
- `config/agent-catalog.json` (Eintrag inkl. `tier`, `triggers`, `requires_mcp`, `depends_on`)
- `scripts/validate_package.py` -> `EXPECTED_AGENT_COUNT`
- `scripts/install.sh` -> `EXPECTED_COUNT`
- `scripts/install.ps1` -> `$Expected`
- `scripts/test_install.sh` -> `EXPECTED`
- `README.md` und `docs/AGENTEN-VERZEICHNIS.md`

`scripts/validate_package.py --mode release` faengt Abweichungen, und der Test
mit dem Profil `voll` stellt sicher, dass jeder Agent ueber mindestens einen
Trigger erreichbar bleibt.
