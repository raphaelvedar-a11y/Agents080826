# MCPs sicher mit Kundenkonten einrichten

Dieses Repository liefert keine aktive Verbindung. MCP-Server werden in der jeweiligen Kunden-Runtime eingerichtet, nicht in den Agentendateien.

## Vorgehen

1. Bedarf je Agent und Datenquelle festlegen.
2. Herausgeber, Quellcode, Berechtigungen und Update-Prozess des MCP-Servers pruefen.
3. Einen eigenen Kunden-Service-Account mit minimalen Rechten verwenden.
4. Credentials in einem Secret Manager oder im geschuetzten Credential Store der Runtime hinterlegen.
5. Zuerst ausschliesslich lesende Tools aktivieren.
6. Mit Testdaten pruefen, welches Konto, welcher Tenant und welche Datenquelle tatsaechlich erreicht werden.
7. Schreibende Tools einzeln freigeben und protokollieren.
8. Nach jeder externen Aktion den persistierten Zustand im Zielsystem verifizieren.

## Nicht in dieses Repository gehoert

- echte MCP-Konfigurationsdateien mit Serveradressen oder Headern
- Tokens, Passwoerter, Zertifikate, Cookies oder OAuth-Artefakte
- Tenant-, Konto-, Kanal- oder Datenbank-IDs
- lokale Pfade zu Secret-Dateien
- exportierte Kunden-, Kommunikations- oder Memory-Daten

## Empfohlene Rechtefolge

`nicht verbunden` -> `read-only Test` -> `read-only produktiv` -> `Draft/Preview` -> `einzeln freigegebene Writes`

Ein erfolgreicher Login oder Tool-Test beweist nicht automatisch, dass das richtige Konto oder der richtige Tenant verbunden ist. Der Zielkontext muss separat geprueft werden.
