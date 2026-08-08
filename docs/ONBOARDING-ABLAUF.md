# Onboarding-Ablauf: wann welche Fragen gestellt werden

Dieses Dokument legt die Reihenfolge fest und begruendet sie. Es beantwortet
die Frage, ob der Kunde die Fragen zu seinem Unternehmen vorab beantwortet oder
erst, nachdem die Agentensituation feststeht.

## Festlegung

**Zweistufig: Kurzprofil vorher, Zugangsdetails nachher.**

| | Stufe 1 – Firmen-Steckbrief | Stufe 2 – Zugaenge |
|---|---|---|
| **Wann** | vor der Priorisierung, direkt nach der Einladung | nach der Installation, je aktivem Agenten |
| **Umfang** | max. 10 Fragen, ca. 5 Minuten | nur die Systeme, die aktive Agenten wirklich brauchen |
| **Inhalt** | Branche, Groesse, Bereiche, eingesetzte Systeme, Sprache, Freigabeverantwortung, Compliance | Konten, MCP-Server, Berechtigungen, Freigabewege |
| **Quelle** | `config/profile-questions.yaml` | `stage2_questions` in `.claude/agent-activation.json` |
| **Blockiert die Installation?** | **nein, niemals** | entfaellt, die Installation ist da schon fertig |

## Warum nicht alles vorher

73 Agenten mit je eigenen Schnittstellenfragen ergeben einen Fragebogen, den
kein Mittelstandsbetrieb durchhaelt — und der zum grossen Teil an Agenten haengt,
die dieser Kunde nie einsetzen wird. Wer vorab nach dem CRM-Zugang fragt,
obwohl der Kunde gar keinen Vertriebsagenten aktiviert, verbrennt Geduld an der
Stelle, an der das Vertrauen erst entsteht.

## Warum nicht alles nachher

Ohne Kurzprofil kann das System nicht priorisieren. Der Kunde bekaeme 73
gleichrangige Agenten ohne Orientierung, welche fuer ihn zaehlen. Genau dieser
Eindruck — „da laeuft irgendwas, aber es ist nicht wirklich fuer uns
eingerichtet" — ist das Problem, das dieser Ablauf loesen soll.

Die wenigen Merkmale, die die Auswahl tatsaechlich unterscheiden (Branche,
Groesse, vorhandene Bereiche, Tool-Stack), sind billig zu erfragen, ohne
Systemkenntnis beantwortbar und aendern sich selten. Sie gehoeren nach vorn.

## Die harte Regel

**Stufe 1 ist kein Tor.** Die Installation wartet nie auf eine Antwort.

Antwortet der Kunde nicht, greift `config/profiles/default.yaml`, es werden
trotzdem **alle** Agentendefinitionen installiert, und das Profil wird spaeter
nachgezogen. Fragen steuern die Priorisierung, nicht den Lieferumfang.

Diese Regel ist die direkte Lehre aus dem Vorfall, der diese Ueberarbeitung
ausgeloest hat: Eine Kundeninstallation endete ohne Fehlermeldung bei 0 von 73
Agenten, weil eine Pruefung vor der Installation stand, die dort nicht
hingehoerte. Seitdem gilt: Zwischen Kunde und vollstaendiger Installation steht
kein einziger optionaler Schritt.

## Vollstaendiger Ablauf

```
Kunde wird zum Repository eingeladen
        |
        |  GitHub-Action "Onboarding starten" (member/workflow_dispatch)
        v
Willkommens-Issue mit Link zum Steckbrief
        |
        |  Kunde oeffnet das Repository in Claude Code
        v
SessionStart-Hook installiert alle 73 Agenten  <-- passiert unabhaengig
        |                                           von jeder Antwort
        v
.claude/agent-install-report.json  ->  "complete": true, "verified": 73
        |
        |  Stufe 1: Steckbrief (Issue-Formular oder Dialog mit Ray)
        v
config/profiles/aktiv.yaml  (per Pull Request zur Freigabe)
        |
        v
.claude/agent-activation.json  ->  aktives Kernteam + Begruendung je Agent
        |                          + MCP-Bedarf fuer Stufe 2
        |
        |  Stufe 2: Zugaenge, nur fuer die aktiven Agenten
        v
read-only testen  ->  schreibende Tools einzeln freigeben  ->  Go-Live
```

## Installationsumfang: alle, nicht eine Auswahl

Installiert werden **immer alle** Agentendefinitionen. Das Profil entscheidet
ausschliesslich, welche davon als aktives Kernteam gelten und welche auf Abruf
bleiben.

Der Grund ist der Vorfall selbst: Ein Kunde, der 73 Agenten erwartet und 18
vorfindet, kann nicht unterscheiden, ob das eine bewusste Auswahl oder ein
Fehlschlag war. Vollstaendige Installation plus sichtbare Priorisierung macht
diesen Unterschied eindeutig — und ein Agent auf Abruf ist ohne Neuinstallation
sofort einsatzbereit.

## Rollen im Ablauf

- **Ray (`team-onboarding`)** fuehrt den Ablauf, prueft den Installationsnachweis
  und stellt die Fragen. Das Runbook steht in seiner Agentendefinition.
- **Donna (`orchestrator`)** entscheidet ueber Eskalationen und Freigaben.
- **Norma (`team-approval-control`)** wacht darueber, dass externe und
  irreversible Aktionen einzeln freigegeben sind.

## Datenschutz im Steckbrief

Der Steckbrief laeuft ueber ein GitHub-Issue und ist damit fuer alle sichtbar,
die Zugriff auf das Repository haben.

- **Keine Zugangsdaten, Passwoerter oder API-Keys** — die gehoeren nach Stufe 2
  und dort in den Passwortspeicher des Kunden, nie ins Repository.
- Die Freigabeverantwortung wird als **Rolle** erfasst, nicht als Name oder
  E-Mail-Adresse.
- `scripts/parse_profile_issue.py` uebernimmt nur Werte von einer Positivliste
  und entfernt E-Mail-artige Angaben, bevor etwas ins Repository geschrieben
  wird. Ein manipuliertes Issue kann darueber weder YAML einschleusen noch
  Agenten aktivieren, die es nicht gibt.
