#!/usr/bin/env bash
# Installiert die Agentendefinitionen und weist nach, dass sie angekommen sind.
#
# Leitsatz: Der Installer liefert und beweist. Er blockiert nur, wenn das PAKET
# defekt ist -- niemals wegen Dateien, die der Kunde selbst angelegt hat.
#
# Exit-Codes
#   0  alle erwarteten Agenten verifiziert
#   1  Paketpruefung fehlgeschlagen (Paket defekt, nichts installiert)
#   2  Aufruffehler
#   3  Installation unvollstaendig (Details stehen in der Ausgabe und im Report)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_DIR/agents"
EXPECTED_COUNT=73

TARGET_DIR="${HOME:-/tmp}/.claude/agents"
REPORT_PATH="$REPO_DIR/.claude/agent-install-report.json"
PROFILE=""
DRY_RUN=0
QUIET=0
FORCE=0
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

usage() {
  cat <<'USAGE'
Usage: install.sh [Optionen]

  --target PATH   Zielordner (Default: $HOME/.claude/agents)
  --user          Kurzform fuer --target $HOME/.claude/agents
  --project       In das Repository installieren (<repo>/.claude/agents)
  --profile FILE  Firmenprofil anwenden und Aktivierungsliste schreiben
  --report FILE   Pfad des Installationsberichts
  --dry-run       Nur anzeigen, was passieren wuerde
  --force         Fremde gleichnamige Dateien ohne Backup ueberschreiben
  --quiet         Nur Zusammenfassung ausgeben
  -h, --help      Diese Hilfe

Der Installer bricht nicht mehr ab, wenn im Zielordner bereits Dateien liegen.
Gleiche Inhalte werden uebersprungen, geaenderte aktualisiert, fremde Dateien
vorher gesichert.
USAGE
}

log()  { [[ "$QUIET" -eq 1 ]] || echo "$@"; }
warn() { echo "WARNUNG: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)  [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_DIR="$2"; shift 2 ;;
    --user)    TARGET_DIR="${HOME:-/tmp}/.claude/agents"; shift ;;
    --project) TARGET_DIR="$REPO_DIR/.claude/agents"; shift ;;
    --profile) [[ $# -ge 2 ]] || { usage; exit 2; }; PROFILE="$2"; shift 2 ;;
    --report)  [[ $# -ge 2 ]] || { usage; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "Unbekannte Option: $1" >&2; usage; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# Paketpruefung. Prueft ausschliesslich das Paket, nie Kundendateien.
# --------------------------------------------------------------------------

bash_preflight() {
  # Rueckfallweg ohne python3. Bewusst schlank, aber nie stillschweigend.
  local count problems=0 file stem
  count="$(find "$SOURCE_DIR" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  if [[ "$count" -ne "$EXPECTED_COUNT" ]]; then
    echo "- erwartet: $EXPECTED_COUNT Agentendateien, gefunden: $count" >&2
    problems=1
  fi
  for file in "$SOURCE_DIR"/*.md; do
    stem="$(basename "$file" .md)"
    if ! grep -Eq "^name: ${stem}[[:space:]]*$" "$file"; then
      echo "- Frontmatter passt nicht zum Dateinamen: $(basename "$file")" >&2
      problems=1
    fi
  done
  if [[ ! -f "$REPO_DIR/config/agent-catalog.json" ]]; then
    echo "- config/agent-catalog.json fehlt" >&2
    problems=1
  fi
  return "$problems"
}

abort_broken_package() {
  echo "ABBRUCH: Das Paket selbst ist unvollstaendig oder inkonsistent." >&2
  echo "Es wurde nichts installiert. Bitte das Repository neu beziehen." >&2
  exit 1
}

run_bash_preflight() {
  PREFLIGHT_MODE="bash-fallback"
  warn "Die Installation laeuft mit der eingebauten Basispruefung weiter."
  warn "Fuer die vollstaendige Pruefung bitte ein funktionierendes python3 bereitstellen."
  bash_preflight || abort_broken_package
  log "PREFLIGHT PASSED (Basispruefung): $EXPECTED_COUNT Agentendateien vorhanden"
}

# Nur ein echtes Pruefergebnis darf die Installation stoppen. Ein fehlendes oder
# defektes python3 ist ein Problem der Umgebung, nicht des Pakets -- frueher hat
# genau das die Installation ohne jede Meldung mit Exit 127 beendet.
PREFLIGHT_MODE="python"
if command -v python3 >/dev/null 2>&1; then
  set +e
  python3 "$SCRIPT_DIR/validate_package.py" --mode preflight
  preflight_rc=$?
  set -e
  case "$preflight_rc" in
    0) ;;
    1) abort_broken_package ;;
    *)
      warn "python3 ist vorhanden, konnte die Pruefung aber nicht ausfuehren (Exit $preflight_rc)."
      run_bash_preflight
      ;;
  esac
else
  warn "python3 wurde nicht gefunden."
  run_bash_preflight
fi

# --------------------------------------------------------------------------
# Installation. Idempotent, ohne Abbruch bei belegtem Zielordner.
# --------------------------------------------------------------------------

log "Zielordner: $TARGET_DIR"
[[ "$DRY_RUN" -eq 1 ]] && log "(Probelauf - es wird nichts geschrieben)"

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$TARGET_DIR"
fi

new_count=0
updated_count=0
unchanged_count=0
backed_up_count=0
backups=""

for source_file in "$SOURCE_DIR"/*.md; do
  base="$(basename "$source_file")"
  target_file="$TARGET_DIR/$base"

  if [[ ! -e "$target_file" ]]; then
    action="neu"
    new_count=$((new_count + 1))
  elif cmp -s "$source_file" "$target_file" 2>/dev/null; then
    unchanged_count=$((unchanged_count + 1))
    [[ "$QUIET" -eq 1 ]] || printf '  %-46s unveraendert\n' "$base"
    continue
  else
    action="aktualisiert"
    updated_count=$((updated_count + 1))
    if [[ "$FORCE" -eq 0 ]]; then
      backup_file="${target_file}.bak-${STAMP//:/}"
      if [[ "$DRY_RUN" -eq 0 ]] && cp "$target_file" "$backup_file" 2>/dev/null; then
        backed_up_count=$((backed_up_count + 1))
        backups="${backups}${base} "
        action="aktualisiert (Backup angelegt)"
      fi
    fi
  fi

  # Ein einzelner Fehlschlag darf den Lauf nicht beenden. Sonst bleiben die
  # restlichen Agenten uninstalliert und niemand erfaehrt, welche fehlen.
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if cp "$source_file" "$target_file" 2>/dev/null; then
      chmod 0644 "$target_file" 2>/dev/null || true
    else
      action="FEHLGESCHLAGEN"
      warn "konnte $base nicht schreiben (Rechte oder Pfad pruefen)"
    fi
  fi
  [[ "$QUIET" -eq 1 ]] || printf '  %-46s %s\n' "$base" "$action"
done

# --------------------------------------------------------------------------
# Verifikation. Ohne diesen Schritt bleibt eine Teilinstallation unbemerkt.
# --------------------------------------------------------------------------

verified=0
missing=""
missing_count=0

for source_file in "$SOURCE_DIR"/*.md; do
  base="$(basename "$source_file")"
  target_file="$TARGET_DIR/$base"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    verified=$((verified + 1))
    continue
  fi
  if [[ -f "$target_file" ]] && cmp -s "$source_file" "$target_file" 2>/dev/null; then
    verified=$((verified + 1))
  else
    missing="${missing}${base%.md} "
    missing_count=$((missing_count + 1))
  fi
done

# --------------------------------------------------------------------------
# Profil anwenden. Optional und niemals installationsblockierend.
# --------------------------------------------------------------------------

profile_status="nicht_angefordert"
if [[ -n "$PROFILE" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    profile_status="uebersprungen_probelauf"
  elif ! command -v python3 >/dev/null 2>&1; then
    profile_status="uebersprungen_kein_python3"
    warn "Profil konnte ohne python3 nicht angewendet werden. Agenten sind trotzdem installiert."
  elif [[ ! -f "$PROFILE" ]]; then
    profile_status="uebersprungen_profil_fehlt"
    warn "Profildatei nicht gefunden: $PROFILE. Agenten sind trotzdem installiert."
  elif python3 "$SCRIPT_DIR/select_agents.py" --profile "$PROFILE" \
        --output "$(dirname "$REPORT_PATH")/agent-activation.json"; then
    profile_status="angewendet"
  else
    profile_status="fehlgeschlagen"
    warn "Profil konnte nicht angewendet werden. Agenten sind trotzdem installiert."
  fi
fi

# --------------------------------------------------------------------------
# Bericht. Das ist der Nachweis, den der Onboarding-Agent spaeter prueft.
# --------------------------------------------------------------------------

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

list_to_json() {
  local item first=1 out="["
  for item in $1; do
    [[ "$first" -eq 1 ]] || out="${out}, "
    out="${out}\"$(json_escape "$item")\""
    first=0
  done
  printf '%s]' "${out}"
}

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$(dirname "$REPORT_PATH")"
  cat > "$REPORT_PATH" <<EOF
{
  "generated_at": "$STAMP",
  "target_dir": "$(json_escape "$TARGET_DIR")",
  "expected": $EXPECTED_COUNT,
  "verified": $verified,
  "complete": $([[ "$verified" -eq "$EXPECTED_COUNT" ]] && echo true || echo false),
  "missing": $(list_to_json "$missing"),
  "new": $new_count,
  "updated": $updated_count,
  "unchanged": $unchanged_count,
  "backups_created": $backed_up_count,
  "preflight_mode": "$PREFLIGHT_MODE",
  "profile": "$(json_escape "$PROFILE")",
  "profile_status": "$profile_status"
}
EOF
fi

# --------------------------------------------------------------------------
# Ergebnis
# --------------------------------------------------------------------------

log ""
log "neu: $new_count   aktualisiert: $updated_count   unveraendert: $unchanged_count   gesichert: $backed_up_count"
[[ -n "$backups" && "$QUIET" -eq 0 ]] && log "Backups angelegt fuer: $backups"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Probelauf abgeschlossen: $EXPECTED_COUNT Agentendefinitionen wuerden nach $TARGET_DIR installiert."
  exit 0
fi

log "Bericht: $REPORT_PATH"

if [[ "$verified" -eq "$EXPECTED_COUNT" ]]; then
  echo "OK: $verified/$EXPECTED_COUNT Agentendefinitionen installiert und verifiziert in $TARGET_DIR"
  exit 0
fi

echo "UNVOLLSTAENDIG: nur $verified/$EXPECTED_COUNT Agentendefinitionen verifiziert." >&2
echo "Es fehlen $missing_count Agenten:" >&2
for name in $missing; do
  echo "  - $name" >&2
done
echo "Bitte Schreibrechte auf $TARGET_DIR pruefen und install.sh erneut ausfuehren." >&2
exit 3
