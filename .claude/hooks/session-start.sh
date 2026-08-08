#!/usr/bin/env bash
# SessionStart-Hook: rollt die Agentendefinitionen aus, sobald jemand das
# Repository in Claude Code oeffnet -- lokal wie im Web.
#
# Damit muss ein eingeladener Kunde nichts von Hand starten. Genau das war der
# Bruch im alten Ablauf: Die Installation hing an einem manuellen Befehl, und
# wenn der fehlschlug, hat es niemand gemerkt.
#
# Zwei Regeln, die dieser Hook nie verletzt:
#   1. Er bricht die Session niemals ab. Ein Installationsproblem wird gemeldet,
#      nicht durch einen harten Fehler versteckt.
#   2. Er ist idempotent. Mehrfaches Ausfuehren aendert nichts und schadet nicht.

# Bewusst kein "set -e": ein Fehlschlag soll berichtet, nicht verschluckt werden.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
INSTALLER="$PROJECT_DIR/scripts/install.sh"
REPORT="$PROJECT_DIR/.claude/agent-install-report.json"

# Aktives Kundenprofil, sonst das Rueckfallprofil. Ein fehlendes Profil darf die
# Installation nicht aufhalten -- es steuert nur die Priorisierung.
PROFILE="$PROJECT_DIR/config/profiles/aktiv.yaml"
if [[ ! -f "$PROFILE" ]]; then
  PROFILE="$PROJECT_DIR/config/profiles/default.yaml"
fi

if [[ ! -x "$INSTALLER" ]]; then
  echo "[agenten-setup] scripts/install.sh nicht ausfuehrbar oder nicht vorhanden."
  echo "[agenten-setup] Bitte pruefen: chmod +x scripts/install.sh"
  exit 0
fi

output="$(bash "$INSTALLER" --project --profile "$PROFILE" --quiet 2>&1)"
rc=$?

echo "[agenten-setup] $(echo "$output" | tail -3 | tr '\n' ' ')"

if [[ "$rc" -eq 0 ]]; then
  if [[ "$PROFILE" == *"default.yaml" ]]; then
    echo "[agenten-setup] Alle Agenten installiert. Es laeuft noch das Rueckfallprofil:"
    echo "[agenten-setup] Der Firmen-Steckbrief (Stufe 1) ist noch offen -- siehe CLAUDE.md."
  else
    echo "[agenten-setup] Alle Agenten installiert, Kundenprofil angewendet."
  fi
else
  echo "[agenten-setup] ACHTUNG: Installation unvollstaendig (Exit $rc)."
  echo "[agenten-setup] Bericht: $REPORT"
  echo "[agenten-setup] Bitte laut melden und reparieren, nicht stillschweigend weiterarbeiten."
fi

# Immer 0: der Hook darf die Session nie blockieren.
exit 0
