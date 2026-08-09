# Arbeitsauftrag fuer den Agenten in diesem Repository

Dieses Repository liefert 73 Agentendefinitionen an einen Kunden aus. Wer hier
eine Sitzung oeffnet, ist in der Regel entweder der Kunde selbst oder begleitet
dessen Onboarding.

## Zuerst: Installationsstand pruefen

Der SessionStart-Hook (`.claude/hooks/session-start.sh`) installiert die Agenten
automatisch beim Oeffnen der Sitzung. Sein Ergebnis steht in
`.claude/agent-install-report.json`.

**Erste Handlung in jeder Sitzung: diesen Bericht lesen.**

- `"complete": true` und `"verified": 73` -> alles in Ordnung, weiter unten.
- `"complete": false` -> **nicht stillschweigend weiterarbeiten.** Das Feld
  `missing` nennt die fehlenden Agenten namentlich. Ursache klaeren
  (meist Schreibrechte auf dem Zielordner), `./scripts/install.sh --project`
  erneut ausfuehren und das Ergebnis benennen.
- Bericht fehlt ganz -> Hook lief nicht. Einmal `./scripts/install.sh --project`
  ausfuehren und melden, dass der Hook nicht gegriffen hat.

Genau dieser Punkt ist in der Vergangenheit schiefgegangen: Eine Installation
endete bei 0 von 73 Agenten, ohne dass es jemand bemerkt hat. Ein unvollstaendiger
Stand wird deshalb immer aktiv gemeldet, nie weggelassen.

**Der Bericht beschreibt immer nur den letzten Lauf.** Sein Pfad haengt am
Repository, nicht am Ziel: `--project` und `--user` schreiben beide nach
`<repo>/.claude/agent-install-report.json`, der zweite Lauf ueberschreibt also
den ersten. Wer beide Ziele bedient, liest sonst einen Bericht, der die andere
Installation beschreibt -- welche gemeint ist, steht im Feld `target_dir`.
Getrennt nachweisen laesst es sich mit `--report`:

```bash
./scripts/install.sh --project --report .claude/agent-install-report.json
./scripts/install.sh --user    --report .claude/agent-install-report.user.json
```

Achtung dabei: die Aktivierungsliste `agent-activation.json` wird neben dem
Bericht abgelegt. Ein anderer `--report`-Pfad verschiebt sie mit, und Stufe 1
unten sucht sie dann am alten Ort vergeblich.

## Danach: Onboarding in zwei Stufen

Die Reihenfolge ist bewusst so gewaehlt und in `docs/ONBOARDING-ABLAUF.md`
begruendet.

### Stufe 1 – Firmen-Steckbrief (vor der Priorisierung)

Pruefen, ob `config/profiles/aktiv.yaml` existiert.

- **Existiert nicht** -> es laeuft das Rueckfallprofil
  `config/profiles/default.yaml`. Den Kunden durch die Fragen aus
  `config/profile-questions.yaml` fuehren (maximal 10, etwa 5 Minuten) oder auf
  das Issue-Formular „Firmen-Steckbrief" verweisen.
- **Existiert** -> Aktivierungsliste in `.claude/agent-activation.json` lesen und
  das aktive Kernteam vorstellen: welche Agenten aktiv sind und warum
  (Feld `reason`).

**Diese Fragen sind kein Tor.** Sie blockieren die Installation nie. Wer nicht
antworten will, bekommt trotzdem alle Agenten installiert und das
Rueckfallprofil als Startpunkt.

### Stufe 2 – Zugaenge, erst nach der Installation

`.claude/agent-activation.json` enthaelt unter `stage2_questions` genau die
Fragen, die fuer die **aktiven** Agenten noetig sind. Nur diese stellen.

Regeln dabei:

- Keine Zugangsdaten in dieses Repository, in Issues, in Commits oder in
  Antworten. Immer nur ein Verweis auf den Passwortspeicher des Kunden.
- Zuerst ausschliesslich lesende Tools aktivieren, schreibende einzeln und
  dokumentiert freigeben (`docs/MCP-SETUP.md`).
- Fehlt ein Zugang: `blocked_missing_access` melden, nichts erfinden.

## Grenzen, die hier immer gelten

- Externe oder irreversible Aktionen brauchen die Freigabe der im Profil
  hinterlegten Verantwortung. Eine frueher erteilte Freigabe gilt nicht fuer
  eine neue Aktion.
- Ein erfolgreicher Tool-Aufruf ist kein Nachweis fuer einen Live-Zustand. Nach
  externen Aktionen den Zustand im Zielsystem separat pruefen.
- Die Anzahl 73 ist fix. Kommt eine Agentendatei hinzu oder faellt eine weg,
  muessen `config/agent-catalog.json`, `scripts/validate_package.py`
  (`EXPECTED_AGENT_COUNT`), `scripts/install.sh` (`EXPECTED_COUNT`),
  `scripts/test_install.sh` und die README gemeinsam angepasst werden.
- **Jede Agentendatei braucht ein `tools`-Feld.** Fehlt es, erbt der Agent alle
  Werkzeuge der Laufzeit — auch `Bash` und `Edit`, die kein Agent dieses Pakets
  bewusst bekommt. Ein fehlendes Feld ist also nicht der neutrale Zustand,
  sondern die weiteste Vergabe im ganzen Paket. Die Grundlinie ist
  `tools: [Read, Write]`; Abweichungen sind einzeln und begruendet
  (`loop-verifier` nur `[Read]`, weil ein Pruefer nichts schreiben soll;
  `team-recht-recherche` zusaetzlich `ToolSearch` und seinen MCP-Server).
  Zulaessig ist nur, was in `validate_package.py` unter `ALLOWED_TOOLS` steht,
  plus MCP-Werkzeuge nach dem Muster `mcp__server__tool`. Wer einem Agenten
  `Bash` geben will, traegt es dort bewusst ein — der Preflight schlaegt sonst
  rot auf.

## Nuetzliche Befehle

```bash
./scripts/install.sh --project              # Agenten ins Repository installieren
./scripts/install.sh --user                 # nach ~/.claude/agents installieren
./scripts/install.sh --project --dry-run    # Probelauf, schreibt nichts
./scripts/test_install.sh                   # Regressionstest der Installation
python3 scripts/validate_package.py --mode preflight   # Paket vollstaendig?
python3 scripts/validate_package.py --mode release     # Auslieferungs-Gate
python3 scripts/select_agents.py --profile config/profiles/aktiv.yaml --print
```
