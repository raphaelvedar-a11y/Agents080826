#!/usr/bin/env python3
"""Leitet aus dem Firmenprofil ab, welche Agenten das aktive Kernteam bilden.

Wichtig: Dieses Skript aendert den Installationsumfang NICHT. Installiert werden
immer alle Agentendefinitionen. Hier wird ausschliesslich entschieden, welche
davon fuer diesen Kunden als aktiv gelten und welche auf Abruf bereitstehen.
Damit bleibt die Installation vollstaendig, auch wenn das Profil fehlt oder
unvollstaendig ist.

Zusaetzlich faellt der MCP-Bedarf fuer Stufe 2 des Onboardings ab: Zugaenge
werden erst abgefragt, wenn feststeht, welche Agenten sie ueberhaupt brauchen.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = ROOT / "config" / "agent-catalog.json"
DEFAULT_PROFILE = ROOT / "config" / "profiles" / "default.yaml"
DEFAULT_OUTPUT = ROOT / ".claude" / "agent-activation.json"

# Fragen fuer Stufe 2. Sie werden nur fuer MCP-Kategorien gestellt, die von
# mindestens einem aktiven Agenten wirklich gebraucht werden.
MCP_QUESTIONS = {
    "email": "Welches E-Mail-System soll angebunden werden (Gmail, Outlook, anderes) und welches Postfach genau?",
    "calendar": "Welcher Kalender soll gelesen werden, und wer darf Termineintraege entwerfen?",
    "cloud_storage": "Wo liegen die Dokumente (Google Drive, OneDrive, anderes) und welcher Ordner ist der Startpunkt?",
    "crm": "Welches CRM nutzt ihr, und welcher Datenbereich soll zunaechst nur gelesen werden?",
    "accounting": "Welche Buchhaltungsloesung nutzt ihr (sevdesk, BuchhaltungsButler, anderes) und wer gibt Buchungen frei?",
    "legal_research": "Welche Rechtsquellen sollen genutzt werden, und gibt es Vorgaben zur Zitierpflicht?",
    "source_control": "Welche Code-Repositories sollen erreichbar sein, und mit welchen Rechten?",
    "database": "Welche Datenbank soll angebunden werden, und welche Tabellen sind zu Beginn nur lesend?",
    "social_media": "Welche Social-Media-Kanaele betreut ihr, und wer gibt Veroeffentlichungen frei?",
    "deployment": "Welche Hosting-/Deployment-Umgebung nutzt ihr, und wer darf Produktion aendern?",
    "memory": "Wo soll das Wissens- und Zustandsmanagement liegen, und wie lange werden Inhalte aufbewahrt?",
}


def load_yaml_subset(path: Path) -> dict:
    """Laedt das Profil.

    Nutzt PyYAML, falls vorhanden. Sonst greift ein bewusst enger Parser fuer
    genau die Struktur, die wir selbst erzeugen: flache Schluessel mit Text-
    oder Listenwert. Damit braucht die Kundeninstallation keine Zusatzpakete.
    """
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        return yaml.safe_load(text) or {}
    except ImportError:
        pass

    data: dict = {}
    current_key: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        list_item = re.match(r"^\s+-\s*(.*)$", line)
        if list_item and current_key:
            value = list_item.group(1).strip().strip('"').strip("'")
            if value:
                # Der erste Listeneintrag macht aus dem Schluessel eine Liste.
                # Ohne diesen Schritt blieben alle Listen leer, und die
                # Agentenauswahl fiele stillschweigend auf das Kernteam
                # zusammen -- ein falsches Ergebnis statt eines Fehlers.
                if not isinstance(data.get(current_key), list):
                    data[current_key] = []
                data[current_key].append(value)
            continue
        key_value = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if key_value:
            key, value = key_value.group(1), key_value.group(2).strip()
            current_key = key
            if value == "[]":
                data[key] = []
            elif value == "":
                data[key] = ""  # kann durch nachfolgende Listeneintraege zur Liste werden
            else:
                data[key] = value.strip('"').strip("'")
    return data


def as_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip().lower() for v in value if str(v).strip()]
    return [str(value).strip().lower()] if str(value).strip() else []


def select(catalog: list[dict], profile: dict) -> dict:
    departments = set(as_list(profile.get("departments")))
    tools = set(as_list(profile.get("tools")))
    industries = set(as_list(profile.get("industry"))) | set(as_list(profile.get("industries")))

    by_name = {entry["technical_name"]: entry for entry in catalog}
    reasons: dict[str, str] = {}

    for entry in catalog:
        name = entry["technical_name"]
        if entry["tier"] == "core":
            reasons[name] = "Kernteam, bei jedem Kunden aktiv"
            continue

        triggers = entry.get("triggers", {})
        hit_dept = departments.intersection(triggers.get("departments", []))
        hit_tool = tools.intersection(triggers.get("tools", []))
        hit_industry = industries.intersection(triggers.get("industries", []))

        if hit_dept:
            reasons[name] = f"Abteilung: {', '.join(sorted(hit_dept))}"
        elif hit_tool:
            reasons[name] = f"Werkzeug: {', '.join(sorted(hit_tool))}"
        elif hit_industry:
            reasons[name] = f"Branche: {', '.join(sorted(hit_industry))}"

    # Abhaengigkeiten nachziehen: ein aktiver Fachagent ohne seine Leitung
    # waere ein halbes Team.
    changed = True
    while changed:
        changed = False
        for name in list(reasons):
            for dependency in by_name.get(name, {}).get("depends_on", []):
                if dependency not in reasons:
                    reasons[dependency] = f"Zuarbeit fuer {by_name[name]['display_name']}"
                    changed = True

    active, on_demand = [], []
    for entry in catalog:
        name = entry["technical_name"]
        row = {
            "technical_name": name,
            "display_name": entry["display_name"],
            "area": entry["area"],
            "tier": entry["tier"],
        }
        if name in reasons:
            active.append({**row, "reason": reasons[name]})
        else:
            on_demand.append(row)

    required_mcp = sorted({
        category
        for entry in catalog
        if entry["technical_name"] in reasons
        for category in entry.get("requires_mcp", [])
    })

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "profile_id": profile.get("profile_id", "unbenannt"),
        "customer_slug": profile.get("customer_slug", ""),
        "installed_total": len(catalog),
        "active_count": len(active),
        "on_demand_count": len(on_demand),
        "active": active,
        "on_demand": on_demand,
        "required_mcp": required_mcp,
        "stage2_questions": [
            {"mcp": category, "question": MCP_QUESTIONS.get(category, f"Welcher Zugang wird fuer {category} genutzt?")}
            for category in required_mcp
        ],
        "note": (
            "Alle Agentendefinitionen sind installiert. Diese Liste steuert nur "
            "die Priorisierung; on_demand-Agenten koennen jederzeit ohne "
            "Neuinstallation aktiviert werden."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default=str(DEFAULT_PROFILE), help="Profildatei (YAML)")
    parser.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="Agentenkatalog")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Zieldatei fuer die Aktivierungsliste")
    parser.add_argument("--print", dest="print_summary", action="store_true", help="Zusammenfassung ausgeben")
    args = parser.parse_args()

    profile_path = Path(args.profile)
    if not profile_path.is_file():
        print(f"Profildatei nicht gefunden: {profile_path}", file=sys.stderr)
        return 2

    try:
        catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))["agents"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"Agentenkatalog nicht lesbar: {exc}", file=sys.stderr)
        return 2

    result = select(catalog, load_yaml_subset(profile_path))

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(
        f"Profil '{result['profile_id']}': {result['active_count']} Agenten aktiv, "
        f"{result['on_demand_count']} auf Abruf, alle {result['installed_total']} installiert."
    )
    if result["required_mcp"]:
        print(f"MCP-Bedarf fuer Stufe 2: {', '.join(result['required_mcp'])}")

    if args.print_summary:
        for row in result["active"]:
            print(f"  [{row['tier']:<8}] {row['display_name']}  <- {row['reason']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
