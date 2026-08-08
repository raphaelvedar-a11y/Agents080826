#!/usr/bin/env python3
"""Wandelt einen ausgefuellten Firmen-Steckbrief (GitHub-Issue-Formular) in ein
Profil unter config/profiles/aktiv.yaml um.

Sicherheitshinweis: Der Issue-Text ist nicht vertrauenswuerdig -- er stammt von
aussen und kann beliebigen Inhalt tragen. Deshalb wird nichts uebernommen, was
nicht auf einer Positivliste steht. Auswahlwerte werden gegen den Agentenkatalog
und feste Listen geprueft, Freitext wird auf harmlose Zeichen reduziert.
Dadurch kann ein manipuliertes Issue weder YAML einschleusen noch Agenten
aktivieren, die es gar nicht gibt.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "config" / "agent-catalog.json"
DEFAULT_OUTPUT = ROOT / "config" / "profiles" / "aktiv.yaml"

# Ueberschrift im gerenderten Issue -> Profilschluessel und Werttyp.
FIELDS = {
    "Kundenkuerzel": ("customer_slug", "slug"),
    "Branche": ("industry", "choice"),
    "Unternehmensgroesse": ("company_size", "choice"),
    "Bereiche": ("departments", "list"),
    "Systeme im Einsatz": ("tools", "list"),
    "Sprache": ("language", "choice"),
    "Zeitzone": ("timezone", "choice"),
    "Freigabeverantwortung": ("approval_owner", "text"),
    "Besondere Anforderungen": ("compliance", "list"),
    "Datenstandort": ("data_location", "choice"),
}

FIXED_ALLOWED = {
    "company_size": {"1", "2-10", "11-50", "51-250", "250+"},
    "language": {"de", "en"},
    "data_location": {"eu", "deutschland", "keine_vorgabe"},
    "compliance": {"avv", "berufsgeheimnis_paragraph_203", "betriebsrat", "iso27001"},
    "timezone": {
        "Europe/Berlin", "Europe/Vienna", "Europe/Zurich", "Europe/London",
        "Europe/Paris", "Europe/Madrid", "Europe/Rome", "UTC",
    },
}

DEFAULTS = {
    "language": "de",
    "timezone": "Europe/Berlin",
    "data_location": "eu",
    "industry": "sonstiges",
    "company_size": "2-10",
    "approval_owner": "Geschaeftsfuehrung",
}

NO_RESPONSE = {"_no response_", "_keine angabe_", "none", ""}


def catalog_vocabulary() -> dict[str, set[str]]:
    """Erlaubte Auswahlwerte direkt aus dem Katalog, damit nichts auseinanderlaeuft."""
    vocab: dict[str, set[str]] = {"departments": set(), "tools": set(), "industries": set()}
    entries = json.loads(CATALOG.read_text(encoding="utf-8"))["agents"]
    for entry in entries:
        for key, values in entry.get("triggers", {}).items():
            vocab.setdefault(key, set()).update(values)
    return vocab


def split_sections(body: str) -> dict[str, str]:
    sections: dict[str, str] = {}
    current: str | None = None
    buffer: list[str] = []
    for line in body.replace("\r\n", "\n").split("\n"):
        heading = re.match(r"^###\s+(.*?)\s*$", line)
        if heading:
            if current is not None:
                sections[current] = "\n".join(buffer).strip()
            current = heading.group(1)
            buffer = []
        elif current is not None:
            buffer.append(line)
    if current is not None:
        sections[current] = "\n".join(buffer).strip()
    return sections


def clean_slug(raw: str) -> str:
    slug = re.sub(r"[^a-z0-9-]+", "-", raw.strip().lower()).strip("-")
    return slug[:60]


def clean_text(raw: str) -> str:
    # E-Mail-artige Angaben werden komplett entfernt, nicht nur entschaerft --
    # ein zerstueckelter Rest waere immer noch eine personenbezogene Angabe im
    # Repository. Danach bleiben nur harmlose Zeichen uebrig, damit aus dem
    # Freitext kein YAML-Konstrukt werden kann.
    text = raw.strip().split("\n")[0]
    text = re.sub(r"\S+@\S+", "", text)
    text = re.sub(r"[^A-Za-z0-9 ÄÖÜäöüß.,&/()-]", "", text)
    return re.sub(r"\s{2,}", " ", text).strip()[:80]


def checked_items(section: str) -> list[str]:
    return [
        match.group(1).strip().lower()
        for match in re.finditer(r"^\s*[-*]\s*\[[xX]\]\s*(.+?)\s*$", section, re.MULTILINE)
    ]


def parse(body: str) -> tuple[dict, list[str]]:
    vocab = catalog_vocabulary()
    sections = split_sections(body)
    profile: dict = {}
    warnings: list[str] = []

    allowed_for = {
        "departments": vocab.get("departments", set()),
        "tools": vocab.get("tools", set()),
        "industry": vocab.get("industries", set()) | {"sonstiges"},
        "compliance": FIXED_ALLOWED["compliance"],
        "company_size": FIXED_ALLOWED["company_size"],
        "language": FIXED_ALLOWED["language"],
        "data_location": FIXED_ALLOWED["data_location"],
        "timezone": FIXED_ALLOWED["timezone"],
    }

    for heading, raw in sections.items():
        matched = next((f for label, f in FIELDS.items() if heading.startswith(label)), None)
        if not matched:
            continue
        key, kind = matched
        value = raw.strip()

        if kind == "list":
            items = [i for i in checked_items(value) if i in allowed_for.get(key, set())]
            rejected = [i for i in checked_items(value) if i not in allowed_for.get(key, set())]
            if rejected:
                warnings.append(f"{key}: unbekannte Auswahl ignoriert ({', '.join(sorted(set(rejected)))})")
            profile[key] = sorted(set(items))
        elif kind == "slug":
            profile[key] = clean_slug(value)
        elif kind == "choice":
            candidate = value.strip().lower() if key != "timezone" else value.strip()
            if value.lower() in NO_RESPONSE or candidate not in allowed_for.get(key, set()):
                if value.lower() not in NO_RESPONSE:
                    warnings.append(f"{key}: Wert '{value[:30]}' nicht erlaubt, Standard verwendet")
                profile[key] = DEFAULTS.get(key, "")
            else:
                profile[key] = candidate
        else:
            cleaned = clean_text(value)
            profile[key] = cleaned if cleaned and value.lower() not in NO_RESPONSE else DEFAULTS.get(key, "")

    for key, fallback in DEFAULTS.items():
        profile.setdefault(key, fallback)
    for key in ("departments", "tools", "compliance"):
        profile.setdefault(key, [])
    profile.setdefault("customer_slug", "")

    if not profile["departments"]:
        warnings.append("keine Bereiche angekreuzt, es greifen die Bereiche des Rueckfallprofils")
        profile["departments"] = ["geschaeftsfuehrung", "vertrieb", "marketing", "finanzen", "office", "kundenservice"]

    return profile, warnings


def render(profile: dict) -> str:
    lines = [
        "# Aktives Kundenprofil.",
        "#",
        "# Erzeugt aus dem Firmen-Steckbrief (Onboarding Stufe 1).",
        "# Nicht von Hand mit Zugangsdaten anreichern -- Zugaenge gehoeren nach",
        "# Stufe 2 und nie in dieses Repository.",
        "",
        "profile_id: aktiv",
        f'customer_slug: "{profile["customer_slug"]}"',
        f'language: {profile["language"]}',
        f'timezone: {profile["timezone"]}',
        f'industry: {profile["industry"]}',
        f'company_size: "{profile["company_size"]}"',
        f'approval_owner: "{profile["approval_owner"]}"',
        f'data_location: {profile["data_location"]}',
        "",
    ]
    for key in ("departments", "tools", "compliance"):
        values = profile.get(key) or []
        if values:
            lines.append(f"{key}:")
            lines.extend(f"  - {value}" for value in values)
        else:
            lines.append(f"{key}: []")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--body-file", help="Datei mit dem Issue-Text; ohne Angabe wird stdin gelesen")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    args = parser.parse_args()

    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else sys.stdin.read()
    profile, warnings = parse(body)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render(profile), encoding="utf-8")

    print(f"Profil geschrieben: {output_path}")
    print(f"  Kunde:    {profile['customer_slug'] or '(kein Kuerzel angegeben)'}")
    print(f"  Branche:  {profile['industry']}")
    print(f"  Bereiche: {', '.join(profile['departments'])}")
    print(f"  Systeme:  {', '.join(profile['tools']) or '(keine angegeben)'}")
    for warning in warnings:
        print(f"  Hinweis:  {warning}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
