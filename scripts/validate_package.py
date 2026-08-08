#!/usr/bin/env python3
"""Paketpruefung in zwei getrennten Modi.

preflight  Installationspruefung beim Kunden. Prueft ausschliesslich, ob das
           ausgelieferte Paket vollstaendig und in sich konsistent ist:
           Agentenzahl, Katalog, Frontmatter, Auswahl-Metadaten, Schutzregeln.
           Es werden ausschliesslich Paketdateien gelesen. Kundeneigene Dateien
           wie config/customer.local.yaml oder .mcp.json werden nie geprueft und
           koennen die Installation daher nicht blockieren.

release    Auslieferungspruefung fuer den Herausgeber und die CI. Enthaelt die
           Preflight-Pruefung und zusaetzlich das Hygiene-Gate gegen Secrets,
           personenbezogene Reste, lokale Pfade und aktive Verbindungsdateien.
           Geprueft werden nur versionierte Dateien, weil nur die ausgeliefert
           werden. Unversionierte Kunden- und Laufzeitdateien sind kein
           Auslieferungsrisiko und werden bewusst ignoriert.

Historie: Bis 2026-08 gab es nur einen Modus, und scripts/install.sh rief ihn
vor jeder Kundeninstallation auf. Dadurch hat das Hygiene-Gate die Installation
abgebrochen, sobald der Kunde die in der README geforderte lokale Konfiguration
angelegt hat -- Ergebnis: 0 von 73 Agenten installiert. Die Trennung hier ist
der Fix dafuer.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AGENTS = ROOT / "agents"
CATALOG = ROOT / "config" / "agent-catalog.json"

EXPECTED_AGENT_COUNT = 73

ALLOWED_TIERS = {"core", "standard", "optional"}
TRIGGER_KEYS = {"departments", "tools", "industries"}

# Der Werkzeugwortschatz des Pakets.
#
# Der Zweck ist nicht Dokumentation, sondern ein Fangnetz. Ein Agent ohne
# tools-Feld erbt in Claude Code ALLE Werkzeuge der Laufzeit -- auch Bash und
# Edit, die kein einziger Agent dieses Pakets bewusst bekommt. Das faellt
# nirgends auf: die Datei ist syntaktisch vollstaendig, der Katalog stimmt,
# und die Installation meldet 73 von 73. Genau so standen 20 der 73 Agenten
# unbemerkt ohne Werkzeuggrenze da, darunter Pentest, Code-Audit und DevOps.
#
# Deshalb hier eine Positivliste statt einer Sperrliste: ein neu eingefuehrtes,
# noch nicht eingeordnetes Werkzeug schlaegt rot auf, statt still
# durchzurutschen. Wer einem Agenten kuenftig Bash geben will, traegt es hier
# bewusst ein -- und diese Zeile ist dann die Stelle, an der jemand hinsieht.
ALLOWED_TOOLS = {"Read", "Write", "ToolSearch"}

# MCP-Werkzeuge werden ueber ihr Namensmuster zugelassen, nicht einzeln: welche
# Server der Kunde aktiviert, entscheidet er selbst (siehe docs/MCP-SETUP.md).
MCP_TOOL_PATTERN = re.compile(r"\Amcp__[a-z0-9_-]+__(?:\*|[A-Za-z0-9_]+)\Z")

SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "github token": re.compile(r"\b(?:gh[opsu]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    "openai-style key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "aws access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "bearer token": re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}"),
    "jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
}

EMAIL_PATTERN = re.compile(r"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}")

# Nicht personenbezogene Maschinenadressen. Das Gate existiert, um Kunden- und
# Mitarbeiteradressen aus dem Paket zu halten, nicht um Bot-Absender in
# Automatisierungen zu verbieten.
EMAIL_ALLOWLIST = re.compile(r"(?i)@users\.noreply\.github\.com\Z|\Anoreply@|\Aexample@")

ACTIVE_CONNECTION_FILES = {
    ".mcp.json",
    "mcp.json",
    "settings.local.json",
    "credentials.json",
    "secrets.json",
}

# Laufzeit- und Kundenpfade. Nur fuer den Rueckfallweg ohne Git relevant.
RUNTIME_IGNORE_PARTS = {
    ".git",
    "__pycache__",
    "node_modules",
    ".claude",
    "secrets",
    "credentials",
    "tokens",
    "logs",
    "memory",
    "runtime-state",
}


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def load_catalog(errors: list[str]) -> list[dict]:
    try:
        return json.loads(CATALOG.read_text(encoding="utf-8"))["agents"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        fail(f"invalid agent catalog: {exc}", errors)
        return []


def check_catalog(catalog_entries: list[dict], errors: list[str]) -> dict[str, dict]:
    """Katalogstruktur, Eindeutigkeit und Auswahl-Metadaten."""
    if len(catalog_entries) != EXPECTED_AGENT_COUNT:
        fail(f"expected {EXPECTED_AGENT_COUNT} catalog entries, found {len(catalog_entries)}", errors)

    catalog: dict[str, dict] = {}
    display_names: set[str] = set()
    personas: set[str] = set()
    required_fields = {
        "technical_name",
        "display_name",
        "persona",
        "work_area",
        "area",
        "tier",
        "triggers",
        "requires_mcp",
        "depends_on",
    }

    for index, entry in enumerate(catalog_entries, start=1):
        if not isinstance(entry, dict) or not required_fields.issubset(entry):
            missing = sorted(required_fields - set(entry)) if isinstance(entry, dict) else ["<not an object>"]
            fail(f"catalog entry {index} is missing required fields: {', '.join(missing)}", errors)
            continue

        technical_name = entry["technical_name"]
        display_name = entry["display_name"]
        persona = entry["persona"]

        if technical_name in catalog:
            fail(f"duplicate catalog technical_name: {technical_name}", errors)
        catalog[technical_name] = entry

        if display_name in display_names:
            fail(f"duplicate catalog display_name: {display_name}", errors)
        display_names.add(display_name)

        if persona in personas:
            fail(f"duplicate catalog persona: {persona}", errors)
        personas.add(persona)

        expected_display = f"{persona} – {entry['work_area']}"
        if display_name != expected_display:
            fail(f"display_name mismatch for {technical_name}: {display_name}", errors)

        if entry["tier"] not in ALLOWED_TIERS:
            fail(f"invalid tier for {technical_name}: {entry['tier']}", errors)

        triggers = entry["triggers"]
        if not isinstance(triggers, dict) or not set(triggers).issubset(TRIGGER_KEYS):
            fail(f"invalid triggers for {technical_name}", errors)
        else:
            for key, values in triggers.items():
                if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                    fail(f"triggers.{key} for {technical_name} must be a list of strings", errors)

        for field in ("requires_mcp", "depends_on"):
            values = entry[field]
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                fail(f"{field} for {technical_name} must be a list of strings", errors)

        if entry["tier"] != "core" and not any(entry["triggers"].get(k) for k in TRIGGER_KEYS):
            fail(f"non-core agent without any trigger is unreachable: {technical_name}", errors)

    for technical_name, entry in catalog.items():
        for dependency in entry.get("depends_on", []):
            if dependency == technical_name:
                fail(f"agent depends on itself: {technical_name}", errors)
            elif dependency not in catalog:
                fail(f"unknown depends_on target for {technical_name}: {dependency}", errors)

    return catalog


def check_agent_tools(path: Path, text: str, errors: list[str]) -> None:
    """Jeder Agent braucht eine ausdrueckliche Werkzeugliste.

    Ein weggelassenes tools-Feld ist kein neutraler Zustand: die Laufzeit
    vergibt dann alle Werkzeuge, die sie hat. Ein fehlendes Feld ist damit die
    weiteste Vergabe im ganzen Paket -- und die einzige, die niemand
    aufgeschrieben hat. Siehe ALLOWED_TOOLS.
    """
    match = re.search(r"(?m)^tools:\s*\[(.*?)\]\s*$", text)
    if not match:
        fail(
            f"missing tools field in {path.relative_to(ROOT)} "
            f"(ohne tools-Feld erbt der Agent alle Werkzeuge der Laufzeit)",
            errors,
        )
        return

    eintraege = [teil.strip() for teil in match.group(1).split(",") if teil.strip()]
    if not eintraege:
        fail(f"empty tools list in {path.relative_to(ROOT)}", errors)
        return

    for werkzeug in eintraege:
        if werkzeug in ALLOWED_TOOLS or MCP_TOOL_PATTERN.match(werkzeug):
            continue
        fail(
            f"unknown tool {werkzeug!r} in {path.relative_to(ROOT)} "
            f"(erlaubt: {', '.join(sorted(ALLOWED_TOOLS))} oder mcp__server__tool)",
            errors,
        )


def check_agent_files(catalog: dict[str, dict], errors: list[str]) -> None:
    """Agentendateien gegen Katalog und Schutzregeln pruefen."""
    agent_files = sorted(AGENTS.glob("*.md"))
    if len(agent_files) != EXPECTED_AGENT_COUNT:
        fail(f"expected {EXPECTED_AGENT_COUNT} agent files, found {len(agent_files)}", errors)

    names: set[str] = set()
    for path in agent_files:
        text = path.read_text(encoding="utf-8")
        match = re.search(r"(?m)^name:\s*([a-z0-9-]+)\s*$", text)
        if not match:
            fail(f"missing or invalid name in {path.relative_to(ROOT)}", errors)
        else:
            name = match.group(1)
            if name in names:
                fail(f"duplicate agent name: {name}", errors)
            names.add(name)
            if name != path.stem:
                fail(f"name/file mismatch: {path.name} -> {name}", errors)
            entry = catalog.get(name)
            if not entry:
                fail(f"agent missing from catalog: {name}", errors)
            else:
                for field in ("display_name", "persona", "work_area"):
                    field_match = re.search(rf'(?m)^{field}:\s*"([^"]+)"\s*$', text)
                    if not field_match:
                        fail(f"missing or invalid {field} in {path.relative_to(ROOT)}", errors)
                    elif field_match.group(1) != entry[field]:
                        fail(f"{field} does not match catalog in {path.relative_to(ROOT)}", errors)
                if f"# {entry['display_name']}" not in text:
                    fail(f"display heading does not match catalog in {path.relative_to(ROOT)}", errors)
        check_agent_tools(path, text, errors)
        if "blocked_missing_access" not in text:
            fail(f"missing access guard in {path.relative_to(ROOT)}", errors)
        if "approval_required" not in text:
            fail(f"missing approval guard in {path.relative_to(ROOT)}", errors)

    missing_files = sorted(set(catalog) - names)
    if missing_files:
        fail(f"catalog entries without agent files: {', '.join(missing_files)}", errors)


def release_scan_files(errors: list[str]) -> list[Path]:
    """Dateien, die ausgeliefert werden oder es demnaechst wuerden.

    Geprueft werden versionierte Dateien UND unversionierte, die nicht
    ignoriert sind -- letztere stehen kurz vor dem Commit und sollen schon vor
    dem Commit auffallen, nicht erst in der CI. Ignorierte Dateien bleiben
    aussen vor: Kunden- und Laufzeitdateien werden nie ausgeliefert.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=True,
        )
        tracked = [ROOT / name for name in result.stdout.decode("utf-8").split("\0") if name]
        if tracked:
            return tracked
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        pass

    print(
        "HINWEIS: keine Git-Dateiliste verfuegbar, Rueckfall auf Verzeichnis-Scan "
        "ohne Laufzeitpfade.",
        file=sys.stderr,
    )
    fallback: list[Path] = []
    for path in sorted(ROOT.rglob("*")):
        if RUNTIME_IGNORE_PARTS.intersection(path.parts):
            continue
        if any(part.startswith(".env") for part in path.parts):
            continue
        if re.search(r"\.local\.", path.name):
            continue
        fallback.append(path)
    return fallback


def check_release_hygiene(errors: list[str]) -> None:
    """Secrets, personenbezogene Reste und aktive Verbindungen im Paket."""
    for path in release_scan_files(errors):
        if path.is_symlink():
            fail(f"symlink not allowed: {path.relative_to(ROOT)}", errors)
            continue
        if not path.is_file():
            continue
        if path.name in ACTIVE_CONNECTION_FILES:
            fail(f"active connection/config filename not allowed: {path.relative_to(ROOT)}", errors)
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            fail(f"binary file not allowed: {path.relative_to(ROOT)}", errors)
            continue

        if re.search(r"/Users/[A-Za-z0-9._-]+/", text):
            fail(f"local macOS user path in {path.relative_to(ROOT)}", errors)

        for match in EMAIL_PATTERN.finditer(text):
            if not EMAIL_ALLOWLIST.search(match.group(0)):
                fail(f"email address in {path.relative_to(ROOT)}", errors)
                break

        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                fail(f"possible {label} in {path.relative_to(ROOT)}", errors)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--mode",
        choices=("release", "preflight"),
        default="release",
        help="release: Auslieferungspruefung inkl. Hygiene-Gate (Default). "
        "preflight: nur Paketintegritaet, fuer die Kundeninstallation.",
    )
    args = parser.parse_args()

    errors: list[str] = []
    catalog = check_catalog(load_catalog(errors), errors)
    check_agent_files(catalog, errors)

    if args.mode == "release":
        check_release_hygiene(errors)

    if errors:
        print(f"VALIDATION FAILED ({args.mode})", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    if args.mode == "preflight":
        print(f"PREFLIGHT PASSED: Paket vollstaendig, {EXPECTED_AGENT_COUNT} Agenten konsistent zum Katalog")
    else:
        print(
            f"VALIDATION PASSED: {EXPECTED_AGENT_COUNT} neutral agent files with unique persona/work-area labels; "
            "no active MCP config or common secret pattern found in versioned files"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
