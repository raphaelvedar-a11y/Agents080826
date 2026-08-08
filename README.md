# Kunden-Agentensystem mit 73 Rollen

Dieses private Paket enthaelt 73 neutrale Agentendefinitionen fuer Claude Code oder kompatible Agenten-Runtimes. Es ist als saubere Ausgangsbasis fuer eine kundenindividuelle Installation gedacht.

## Lieferumfang

- `agents/`: 73 Agentendefinitionen aus Strategie, Vertrieb, Marketing, Finanzen, Recht, Produkt, Engineering, Security und Operations
- `docs/AGENTEN-VERZEICHNIS.md`: lesbare Gesamtliste nach dem Muster `Harvey – Vertrieb`
- `config/agent-catalog.json`: maschinenlesbare Zuordnung von technischer ID, Persona und Arbeitsbereich
- `config/customer.example.yaml`: neutrale Kundenkonfiguration ohne echte Konten
- `config/mcp-catalog.example.yaml`: optionale MCP-Kategorien, standardmaessig deaktiviert
- `config/profile-questions.yaml`: Firmen-Steckbrief (Onboarding Stufe 1)
- `config/profiles/`: Rueckfallprofil und Beispielprofile fuer die Agentenauswahl
- `docs/MCP-SETUP.md`: sichere Einrichtung mit kundeneigenen Zugaengen
- `docs/ONBOARDING-ABLAUF.md`: welche Fragen wann gestellt werden und warum
- `docs/INSTALLATION-RUNBOOK.md`: Installation, Nachweis und Fehlerbehebung
- `scripts/install.sh` / `scripts/install.ps1`: Installation mit Verifikation
- `scripts/validate_package.py`: Paketpruefung in zwei Modi (`preflight`, `release`)
- `scripts/parse_profile_issue.py`: macht aus dem ausgefuellten Steckbrief-Issue
  ein Profil; uebernimmt nur, was auf einer Positivliste steht
- `scripts/select_agents.py`: leitet aus dem Firmenprofil das aktive Kernteam ab
- `scripts/test_install.sh`: Regressionstest der Installation
- `scripts/abgleich.py`: vergleicht dieses Paket mit einem zweiten Bestand
- `.claude/hooks/session-start.sh`: installiert die Agenten automatisch beim Oeffnen

## Sicherheitszustand bei Auslieferung

- keine Tokens, Passwoerter, API-Keys oder Zugangsdaten
- keine aktiven MCP-Verbindungen
- keine identifizierenden Personen-, Firmen-, Mandanten-, Kunden- oder Projektinhalte des Herausgebers
- keine lokalen Quellpfade, Logs, Memories oder produktiven Runtime-Zustaende
- keine Git-Historie des Quellsystems
- externe oder irreversible Aktionen bleiben freigabepflichtig

Die MCP-Liste ist nur ein neutraler Katalog. Der Kunde waehlt die benoetigten Server selbst aus, installiert sie aus einer vertrauenswuerdigen Quelle und authentifiziert sie mit eigenen Konten.

Die Vornamen in den Agentendefinitionen sind reine Persona-Bezeichnungen. Jeder Agent zeigt seinen Namen und Arbeitsbereich direkt im Titel und Frontmatter; die technische ID bleibt fuer bestehende Handoffs stabil.

Die vollstaendige Liste steht im [Agenten-Verzeichnis](docs/AGENTEN-VERZEICHNIS.md).

## Schnellstart

**In der Regel ist nichts zu tun.** Wird das Repository in Claude Code geoeffnet,
installiert der SessionStart-Hook alle 73 Agenten automatisch.

Manuell, etwa zur Reparatur:

```bash
./scripts/install.sh --project     # nach <repo>/.claude/agents
./scripts/install.sh --user        # nach ~/.claude/agents
.\scripts\install.ps1 -Project     # Windows ohne Bash
```

Der Installer ist idempotent: gleiche Inhalte werden uebersprungen, geaenderte
aktualisiert, fremde gleichnamige Dateien vorher gesichert. Er bricht **nicht**
ab, weil im Zielordner schon Dateien liegen oder weil eigene Konfigurationen im
Arbeitsverzeichnis existieren.

Nach dem Lauf steht das Ergebnis in `.claude/agent-install-report.json`. Nur
`"complete": true` mit `"verified": 73` zaehlt als erfolgreiche Installation;
andernfalls nennt das Feld `missing` die fehlenden Agenten namentlich. Details
und Fehlerbehebung: [Installations-Runbook](docs/INSTALLATION-RUNBOOK.md).

## Onboarding in zwei Stufen

**Stufe 1 – Firmen-Steckbrief (vor der Priorisierung, ca. 5 Minuten).**
Branche, Groesse, vorhandene Bereiche, eingesetzte Systeme, Freigabeverantwortung.
Diese Angaben entscheiden, welche Agenten das **aktive Kernteam** bilden.

**Stufe 2 – Zugaenge (nach der Installation).**
Konten und MCP-Server, und zwar nur fuer die Systeme, die aktive Agenten wirklich
brauchen.

Der Steckbrief blockiert die Installation **nie**. Bleibt er offen, greift
`config/profiles/default.yaml`, und es werden trotzdem alle Agenten installiert.
Installiert sind immer alle 73; das Profil steuert ausschliesslich die
Priorisierung, und ein Agent „auf Abruf" ist ohne Neuinstallation sofort
einsatzbereit.

Begruendung der Reihenfolge: [Onboarding-Ablauf](docs/ONBOARDING-ABLAUF.md).

```bash
python3 scripts/select_agents.py --profile config/profiles/aktiv.yaml --print
```

## Kundenkonfiguration

1. `config/customer.example.yaml` als lokale, nicht versionierte `config/customer.local.yaml` kopieren.
2. Unternehmensziele, Sprache, Zeitzone und Freigabeverantwortliche eintragen.
3. Nur benoetigte MCPs aus `config/mcp-catalog.example.yaml` auswaehlen.
4. MCPs ausserhalb dieses Repositories installieren und mit kundeneigenen Zugaengen verbinden.
5. Zuerst read-only testen; schreibende Tools erst nach dokumentierter Freigabe aktivieren.

Diese lokalen Dateien beeinflussen die Installation nicht und werden von ihr nie
gelesen.

## Qualitaetssicherung

```bash
python3 scripts/validate_package.py --mode preflight   # Paket vollstaendig?
python3 scripts/validate_package.py --mode release     # Auslieferungs-Gate
./scripts/test_install.sh                              # 15 Installationsszenarien
```

`preflight` prueft nur das Paket und laeuft vor jeder Installation. `release`
prueft zusaetzlich auf Secrets und personenbezogene Reste, betrachtet dabei aber
ausschliesslich versionierte Dateien — es ist ein Auslieferungs-Gate und steht
der Kundeninstallation nie im Weg.

## Betriebsgrenze

Die Agentendefinitionen sind Prompts und Richtlinien, kein bereits verbundenes Produktivsystem. Ein Agent kann nur die Tools verwenden, die die Kunden-Runtime tatsaechlich bereitstellt. Fehlender Zugriff muss als `blocked_missing_access` gemeldet werden.

## Lizenz

Dieses Paket ist proprietaer. Nutzung und Weitergabe richten sich nach dem jeweiligen Kundenvertrag. Siehe `LICENSE.md`.
