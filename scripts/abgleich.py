#!/usr/bin/env python3
"""Abgleich zweier Agentenpakete.

    python3 abgleich.py <vorlage> <eigenes>

Beantwortet die Frage, wegen der es diesen Abgleich gibt: hatten die Agenten
in der Vorlage ein tools-Feld, das unterwegs verlorenging -- oder fehlte es
dort ebenso?

Liest nur, schreibt nichts. Beide Argumente sind Wurzelverzeichnisse eines
Pakets mit agents/*.md.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def agenten(wurzel: Path) -> dict[str, dict]:
    verzeichnis = wurzel / "agents"
    if not verzeichnis.is_dir():
        sys.exit(f"Kein agents/-Verzeichnis unter {wurzel}")
    bestand = {}
    for pfad in sorted(verzeichnis.glob("*.md")):
        text = pfad.read_text(encoding="utf-8")
        treffer = FRONTMATTER.match(text)
        kopf = treffer.group(1) if treffer else ""
        werkzeuge = re.search(r"(?m)^tools:\s*(.+)$", kopf)
        bestand[pfad.stem] = {
            "tools": werkzeuge.group(1).strip() if werkzeuge else None,
            "hash": hashlib.sha256(text.encode("utf-8")).hexdigest()[:12],
        }
    return bestand


def hauptteil(vorlage_pfad: str, eigenes_pfad: str) -> int:
    vorlage = agenten(Path(vorlage_pfad))
    eigenes = agenten(Path(eigenes_pfad))

    print(f"Vorlage: {len(vorlage)} Agenten aus {vorlage_pfad}")
    print(f"Eigenes: {len(eigenes)} Agenten aus {eigenes_pfad}\n")

    nur_vorlage = sorted(set(vorlage) - set(eigenes))
    nur_eigenes = sorted(set(eigenes) - set(vorlage))
    gemeinsam = sorted(set(vorlage) & set(eigenes))

    if nur_vorlage:
        print(f"NUR IN DER VORLAGE ({len(nur_vorlage)}) -- diese fehlen:")
        for name in nur_vorlage:
            print(f"  - {name}")
        print()
    if nur_eigenes:
        print(f"NUR IM EIGENEN PAKET ({len(nur_eigenes)}):")
        for name in nur_eigenes:
            print(f"  + {name}")
        print()
    if not nur_vorlage and not nur_eigenes:
        print("Bestand deckungsgleich, keine Datei fehlt oder ist zu viel.\n")

    # Die eigentliche Frage.
    print("WERKZEUGFELDER")
    ohne_beide, ohne_nur_eigenes, nur_eigenes_gesetzt, abweichend = [], [], [], []
    gleich = 0
    for name in gemeinsam:
        v, e = vorlage[name]["tools"], eigenes[name]["tools"]
        if v is None and e is None:
            ohne_beide.append(name)
        elif v is not None and e is None:
            ohne_nur_eigenes.append((name, v))
        elif v is None and e is not None:
            nur_eigenes_gesetzt.append((name, e))
        elif v != e:
            abweichend.append((name, v, e))
        else:
            gleich += 1

    print(f"  identisch:                     {gleich}")
    if ohne_nur_eigenes:
        print(f"\n  BEIM UEBERTRAGEN VERLOREN ({len(ohne_nur_eigenes)}) --")
        print("  Vorlage hat ein tools-Feld, das eigene Paket nicht:")
        for name, v in ohne_nur_eigenes:
            print(f"    {name}: Vorlage {v}")
    if ohne_beide:
        print(f"\n  IN BEIDEN OHNE tools-Feld ({len(ohne_beide)}) --")
        print("  die Luecke war von Anfang an im Original:")
        for name in ohne_beide:
            print(f"    {name}")
    if nur_eigenes_gesetzt:
        print(f"\n  NUR IM EIGENEN PAKET GESETZT ({len(nur_eigenes_gesetzt)}) --")
        print("  die Vorlage hat dort kein tools-Feld, das eigene Paket schon:")
        for name, e in nur_eigenes_gesetzt:
            print(f"    {name}: {e}")
    if abweichend:
        print(f"\n  ABWEICHEND ({len(abweichend)}):")
        for name, v, e in abweichend:
            print(f"    {name}\n      Vorlage: {v}\n      Eigenes: {e}")

    inhaltlich = [n for n in gemeinsam if vorlage[n]["hash"] != eigenes[n]["hash"]]
    print(f"\nINHALTLICH GEAENDERT: {len(inhaltlich)} von {len(gemeinsam)}")
    for name in inhaltlich[:20]:
        print(f"  ~ {name}")
    if len(inhaltlich) > 20:
        print(f"  ... und {len(inhaltlich) - 20} weitere")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    raise SystemExit(hauptteil(sys.argv[1], sys.argv[2]))
