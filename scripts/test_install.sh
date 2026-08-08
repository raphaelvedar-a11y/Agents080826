#!/usr/bin/env bash
# Regressionstest fuer die Kundeninstallation.
#
# Jedes Szenario hier ist ein Fehlerbild, das eine Kundeninstallation real
# zerlegt hat oder zerlegen koennte. Der Test fixiert die Zusage: Egal was der
# Kunde in seinem Arbeitsverzeichnis anlegt und egal wie karg seine Umgebung
# ist -- entweder landen alle Agenten im Zielordner, oder es steht namentlich
# da, welche fehlen.
#
# Aufruf: scripts/test_install.sh
# Exit 0 = alle Szenarien bestanden.

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED=73

SANDBOX="$(mktemp -d)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

passed=0
failed=0

# Testdaten werden zur Laufzeit zusammengesetzt. In dieser versionierten Datei
# soll weder eine vollstaendige E-Mail-Adresse noch ein tokenartiger String
# stehen -- sonst schlaegt das Auslieferungs-Gate hier zu Recht an, und die
# einzige Alternative waere eine Ausnahme, die das Gate aufweicht.
FIXTURE_MAIL_LOCAL="chef"
FIXTURE_MAIL_DOMAIN="kundenfirma.de"
FIXTURE_MAIL="${FIXTURE_MAIL_LOCAL}@${FIXTURE_MAIL_DOMAIN}"

FIXTURE_TOKEN_PREFIX="ghp"
FIXTURE_TOKEN="${FIXTURE_TOKEN_PREFIX}_abcdefghijklmnopqrstuvwxyz0123"

ok()   { printf '  PASS  %s\n' "$1"; passed=$((passed + 1)); }
bad()  { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; failed=$((failed + 1)); }

count_agents() { find "$1" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }

# Erwartet: Installation laeuft durch und alle Agenten sind verifiziert.
expect_complete() {
  local label="$1" rc="$2" target="$3"
  local n; n="$(count_agents "$target")"
  if [[ "$rc" -eq 0 && "$n" -eq "$EXPECTED" ]]; then
    ok "$label ($n/$EXPECTED)"
  else
    bad "$label" "Exit $rc, $n/$EXPECTED Agenten installiert"
  fi
}

echo "Sandbox: $SANDBOX"
cp -R "$REPO_DIR" "$SANDBOX/repo"
rm -rf "$SANDBOX/repo/.claude/agents" "$SANDBOX/repo/.claude/agent-install-report.json" \
       "$SANDBOX/repo/.claude/agent-activation.json"
REPO="$SANDBOX/repo"

echo ""
echo "== Installation unter Kundenbedingungen =="

# 1) Der Kunde legt die in der README geforderte lokale Konfiguration an.
#    Frueher: Hygiene-Gate schlug an, 0/73 installiert.
printf 'governance:\n  approval_owner: "%s"\n' "$FIXTURE_MAIL" > "$REPO/config/customer.local.yaml"
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t1" --quiet >/dev/null 2>&1
expect_complete "Kundeneigene customer.local.yaml mit E-Mail" "$?" "$SANDBOX/t1"

# 2) Der Kunde richtet MCP ein und legt dabei .mcp.json an.
echo '{"mcpServers":{}}' > "$REPO/.mcp.json"
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t2" --quiet >/dev/null 2>&1
expect_complete "Kundeneigene .mcp.json im Arbeitsverzeichnis" "$?" "$SANDBOX/t2"

# 3) Im Zielordner liegt bereits eine gleichnamige eigene Datei.
#    Frueher: Abbruch, 1/73.
mkdir -p "$SANDBOX/t3"
echo "# eigener Agent des Kunden" > "$SANDBOX/t3/team-crm.md"
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t3" --quiet >/dev/null 2>&1
rc=$?
expect_complete "Belegter Zielordner" "$rc" "$SANDBOX/t3"
if ls "$SANDBOX/t3"/team-crm.md.bak-* >/dev/null 2>&1; then
  ok "Fremde Datei wurde vor dem Ueberschreiben gesichert"
else
  bad "Fremde Datei wurde vor dem Ueberschreiben gesichert" "kein Backup gefunden"
fi

# 4a) python3 ist da, laesst sich aber nicht ausfuehren.
#     Frueher: Exit 127 ohne jede Meldung, 0/73.
mkdir -p "$SANDBOX/fakebin"
printf '#!/bin/sh\nexit 127\n' > "$SANDBOX/fakebin/python3"
chmod +x "$SANDBOX/fakebin/python3"
PATH="$SANDBOX/fakebin:$PATH" bash "$REPO/scripts/install.sh" --target "$SANDBOX/t4a" --quiet >/dev/null 2>&1
expect_complete "python3 vorhanden aber defekt" "$?" "$SANDBOX/t4a"

# 4b) Gar kein python3 im PATH.
mkdir -p "$SANDBOX/minbin"
for cmd in bash sh cp mkdir chmod cmp basename dirname find wc grep sed tr date ls rm cat; do
  p="$(command -v "$cmd" 2>/dev/null)" && ln -sf "$p" "$SANDBOX/minbin/$cmd"
done
env -i HOME="$SANDBOX" PATH="$SANDBOX/minbin" bash "$REPO/scripts/install.sh" \
  --target "$SANDBOX/t4b" --quiet >/dev/null 2>&1
expect_complete "Kein python3 im PATH" "$?" "$SANDBOX/t4b"

# 5) Zweiter Lauf als Update und als Reparatur einer Teilinstallation.
#    Frueher: Abbruch ohne --force, keine Reparatur moeglich.
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t5" --quiet >/dev/null 2>&1
rm -f "$SANDBOX/t5/team-vertrieb.md" "$SANDBOX/t5/team-finanzen.md"
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t5" --quiet >/dev/null 2>&1
expect_complete "Zweitlauf repariert eine Teilinstallation" "$?" "$SANDBOX/t5"

echo ""
echo "== Ehrliche Fehlermeldung statt stiller Teilinstallation =="

# 6) Zwei Ziele sind blockiert. Erwartet: Exit 3 und namentliche Meldung.
mkdir -p "$SANDBOX/t6/team-vertrieb.md" "$SANDBOX/t6/loop-verifier.md"
out="$(bash "$REPO/scripts/install.sh" --target "$SANDBOX/t6" --quiet 2>&1)"
rc=$?
if [[ "$rc" -eq 3 ]] && echo "$out" | grep -q 'team-vertrieb' && echo "$out" | grep -q 'loop-verifier'; then
  ok "Teilinstallation meldet Exit 3 und nennt die fehlenden Agenten"
else
  bad "Teilinstallation meldet Exit 3 und nennt die fehlenden Agenten" "Exit $rc"
fi
if [[ "$(count_agents "$SANDBOX/t6")" -eq 71 ]]; then
  ok "Blockierte Einzeldateien stoppen die uebrigen 71 nicht"
else
  bad "Blockierte Einzeldateien stoppen die uebrigen 71 nicht" "$(count_agents "$SANDBOX/t6")/71"
fi

echo ""
echo "== Probelauf und Profil =="

# 7) --dry-run darf nichts anlegen.
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t7" --dry-run --quiet >/dev/null 2>&1
if [[ "$?" -eq 0 && ! -d "$SANDBOX/t7" ]]; then
  ok "Probelauf schreibt nichts"
else
  bad "Probelauf schreibt nichts" "Zielordner wurde angelegt"
fi

# 8) Ein fehlendes Profil darf die Installation nicht kippen.
bash "$REPO/scripts/install.sh" --target "$SANDBOX/t8" \
  --profile "$REPO/config/profiles/existiert-nicht.yaml" --quiet >/dev/null 2>&1
expect_complete "Fehlendes Profil blockiert die Installation nicht" "$?" "$SANDBOX/t8"

# 9) Jeder Agent muss ueber mindestens ein Profil erreichbar sein.
aktive_agenten() {
  # $1 = zusaetzlicher PYTHONPATH (leer = normale Umgebung)
  PYTHONPATH="${1:-}" python3 "$REPO/scripts/select_agents.py" \
    --profile "$REPO/config/profiles/voll.yaml" \
    --output "$SANDBOX/act.json" 2>/dev/null | grep -o '[0-9]\+ Agenten aktiv' | grep -o '[0-9]\+'
}

if command -v python3 >/dev/null 2>&1; then
  n_active="$(aktive_agenten)"
  if [[ "$n_active" == "$EXPECTED" ]]; then
    ok "Vollprofil aktiviert alle $EXPECTED Agenten (kein unerreichbarer Agent)"
  else
    bad "Vollprofil aktiviert alle $EXPECTED Agenten" "nur $n_active aktiv"
  fi

  # 9b) Dasselbe ohne PyYAML. Beim Kunden ist PyYAML nicht garantiert, dann
  #     greift der eingebaute Parser. Der hat einmal alle Listen leer gelassen
  #     und damit stillschweigend ein zu kleines Kernteam geliefert -- ein
  #     falsches Ergebnis ohne Fehlermeldung. Beide Pfade werden geprueft.
  mkdir -p "$SANDBOX/noyaml"
  printf 'raise ImportError("PyYAML in diesem Test bewusst nicht verfuegbar")\n' > "$SANDBOX/noyaml/yaml.py"
  n_active_noyaml="$(aktive_agenten "$SANDBOX/noyaml")"
  if [[ "$n_active_noyaml" == "$EXPECTED" ]]; then
    ok "Vollprofil aktiviert alle $EXPECTED Agenten auch ohne PyYAML"
  else
    bad "Vollprofil aktiviert alle $EXPECTED Agenten auch ohne PyYAML" "nur $n_active_noyaml aktiv"
  fi
fi

echo ""
echo "== Auslieferungs-Gate bleibt scharf =="

if command -v python3 >/dev/null 2>&1; then
  # 10) Unversionierte Kundendateien duerfen das Release-Gate NICHT ausloesen.
  #     (customer.local.yaml und .mcp.json liegen aus Szenario 1+2 noch da.)
  if (cd "$REPO" && python3 scripts/validate_package.py --mode release >/dev/null 2>&1); then
    ok "Release-Gate ignoriert unversionierte Kundendateien"
  else
    bad "Release-Gate ignoriert unversionierte Kundendateien" "Gate hat angeschlagen"
  fi

  # 11) Ein echtes Secret in einer versionierten Datei muss weiterhin auffliegen.
  printf '\ntoken: %s\n' "$FIXTURE_TOKEN" >> "$REPO/docs/MCP-SETUP.md"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode release >/dev/null 2>&1); then
    bad "Release-Gate faengt Secrets in versionierten Dateien" "Secret wurde durchgelassen"
  else
    ok "Release-Gate faengt Secrets in versionierten Dateien"
  fi

  # 12) Und der Preflight darf davon unbeeindruckt bleiben -- er ist kein
  #     Hygiene-Gate und darf die Kundeninstallation nie blockieren.
  if (cd "$REPO" && python3 scripts/validate_package.py --mode preflight >/dev/null 2>&1); then
    ok "Preflight bleibt vom Hygiene-Gate unabhaengig"
  else
    bad "Preflight bleibt vom Hygiene-Gate unabhaengig" "Preflight hat angeschlagen"
  fi

  # 13) Noch nicht committete, aber auch nicht ignorierte Dateien muessen schon
  #     vor dem Commit auffallen. Ohne das faellt eine Secret-Leiche in einer
  #     neuen Datei erst in der CI auf -- genau so ist es einmal passiert.
  (cd "$REPO" && git checkout -- docs/MCP-SETUP.md 2>/dev/null) || true
  printf 'kontakt: %s\n' "$FIXTURE_MAIL" > "$REPO/NEUE-UNGETRACKTE-DATEI.md"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode release >/dev/null 2>&1); then
    bad "Release-Gate sieht auch noch nicht committete Dateien" "neue Datei wurde uebersehen"
  else
    ok "Release-Gate sieht auch noch nicht committete Dateien"
  fi
  rm -f "$REPO/NEUE-UNGETRACKTE-DATEI.md"

  # 14) Ein fehlendes tools-Feld muss den Preflight rot machen. Es sieht nach
  #     nichts aus -- die Datei bleibt syntaktisch vollstaendig, der Katalog
  #     stimmt, die Installation meldet 73 von 73 -- vergibt aber in Wahrheit
  #     ALLE Werkzeuge der Laufzeit. Genau so standen 20 der 73 Agenten
  #     unbemerkt ohne Werkzeuggrenze da, darunter Pentest und Code-Audit.
  cp "$REPO/agents/team-security-pentest.md" "$REPO/pentest.sicherung"
  grep -v '^tools:' "$REPO/pentest.sicherung" > "$REPO/agents/team-security-pentest.md"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode preflight >/dev/null 2>&1); then
    bad "Fehlendes tools-Feld macht den Preflight rot" "Agent ohne Werkzeuggrenze durchgelassen"
  else
    ok "Fehlendes tools-Feld macht den Preflight rot"
  fi

  # 15) Und ein Werkzeug ausserhalb des Wortschatzes ebenso. Ohne diese Zeile
  #     pruefte 14) nur die Anwesenheit des Feldes, nicht seinen Inhalt --
  #     tools: [Read, Write, Bash] waere gruen durchgelaufen.
  sed 's/^tools: \[Read, Write\]/tools: [Read, Write, Bash]/' \
    "$REPO/pentest.sicherung" > "$REPO/agents/team-security-pentest.md"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode preflight >/dev/null 2>&1); then
    bad "Unbekanntes Werkzeug macht den Preflight rot" "Bash wurde durchgelassen"
  else
    ok "Unbekanntes Werkzeug macht den Preflight rot"
  fi
  mv "$REPO/pentest.sicherung" "$REPO/agents/team-security-pentest.md"

  # 16) Die Bash-Ausnahme gilt namentlich, nicht als Gattung. 15) zeigt, dass
  #     Bash beim Pentester rot wird; hier, dass sie beim security-reviewer
  #     gruen ist. Ohne beide Haelften waere nicht geprueft, ob die Ausnahme
  #     ueberhaupt greift -- oder ob sie in Wahrheit fuer alle gilt.
  cp "$REPO/agents/security-reviewer.md" "$REPO/reviewer.sicherung"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode preflight >/dev/null 2>&1); then
    ok "Bash ist fuer security-reviewer namentlich erlaubt"
  else
    bad "Bash ist fuer security-reviewer namentlich erlaubt" "Ausnahme greift nicht"
  fi

  # 17) Und die Ausnahme deckt genau ein Werkzeug ab, nicht alles Weitere.
  sed 's/^tools: \[Read, Bash\]/tools: [Read, Bash, Edit]/' \
    "$REPO/reviewer.sicherung" > "$REPO/agents/security-reviewer.md"
  if (cd "$REPO" && python3 scripts/validate_package.py --mode preflight >/dev/null 2>&1); then
    bad "Ausnahme deckt nur Bash, nicht Edit" "Edit wurde durchgelassen"
  else
    ok "Ausnahme deckt nur Bash, nicht Edit"
  fi
  mv "$REPO/reviewer.sicherung" "$REPO/agents/security-reviewer.md"
fi

echo ""
echo "-----------------------------------------------"
echo "bestanden: $passed   fehlgeschlagen: $failed"
[[ "$failed" -eq 0 ]] || exit 1
echo "Alle Szenarien bestanden."
