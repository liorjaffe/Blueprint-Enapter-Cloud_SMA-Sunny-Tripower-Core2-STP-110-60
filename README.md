# SMA Sunny Tripower CORE2 STP110-60

Enapter Blueprint für die lesende Überwachung eines SMA Sunny Tripower CORE2 STP110-60 über SunSpec Modbus TCP.

## Status

Der Blueprint wurde am 9. September 2026 erfolgreich auf einem Enapter Virtual UCM getestet. Das Gerät wurde erkannt und liefert fortlaufend Telemetriedaten. Der erfolgreiche Verbindungstest meldete:

```text
SunSpec connection ready, holdings at register 40000 with Unit ID 1
```

Die anschließenden Telemetriedaten enthielten unter anderem den Status `running`, AC-Leistung, DC-Leistung, Spannungen, Ströme, Frequenz, Energie und Wechselrichtertemperatur. [1]

## Dateien

Der Blueprint besteht aus zwei Dateien:

```text
manifest.yml
main.lua
```

`manifest.yml` beschreibt die Eigenschaften, Telemetrie und Alarme. `main.lua` implementiert die SunSpec-Modbus-TCP-Kommunikation.

## Voraussetzungen

- Ein Enapter Gateway mit einem Virtual UCM.
- Ein für Ethernet und Modbus TCP erreichbarer SMA-Wechselrichter.
- TCP-Port 502 zwischen Gateway und Wechselrichter.
- SunSpec beziehungsweise Modbus TCP am SMA aktiviert.
- Die aktuelle `main.lua` aus diesem Projekt.

Ein Virtual UCM läuft als Software auf dem Enapter Gateway und ist für Ethernet- und Modbus-TCP-Geräte vorgesehen. [2]

## Verbindung konfigurieren

Die Verbindung wird in `main.lua` eingestellt:

```lua
local DEVICE_HOST = "192.168.1.123"
local DEVICE_PORT = 502
local UNIT_ID = 1
```

`DEVICE_HOST` muss die IP-Adresse sein, die vom Enapter Gateway aus erreichbar ist. Wenn Gateway und Wechselrichter im selben lokalen Netzwerk stehen, sollte normalerweise die lokale IP-Adresse des Wechselrichters verwendet werden. Eine Webanmeldung am SMA ist für SunSpec Modbus TCP nicht Bestandteil dieses Lua-Codes.

Der aktuell getestete Wechselrichter antwortete mit:

```text
Registertyp: holdings
Startadresse: 40000
Unit ID: 1
```

Die Software probiert zusätzlich weitere Kombinationen, falls sich die Registerabbildung einer Installation unterscheidet.

## Manifest

Das Projekt verwendet absichtlich die ältere, vom Zielsystem akzeptierte Blueprint-Spezifikation:

```yaml
blueprint_spec: device/1.0

communication_module:
  product: ENP-VIRTUAL
  lua_file: main.lua
```

`runtime`, `requirements`, `options` und die neue `configuration`-Struktur werden in diesem Projekt nicht verwendet, weil der eingesetzte Validator nur `device/1.0` akzeptiert.

## Automatische Erkennung

Beim Start führt `main.lua` folgende Schritte aus:

1. Die Lua-Modbus-API wird aus der aktuellen Enapter-Runtime geladen. Als Rückfall wird zusätzlich ein Modulimport versucht.
2. Der SunSpec-Header wird mit einer kurzen Zwei-Register-Abfrage gesucht.
3. Geprüft werden Holding- und Input-Register.
4. Geprüft werden die Startadressen `0`, `40000` und `40001`.
5. Geprüft werden die Unit-IDs `1`, `3`, `2` und `4`.
6. Nach erfolgreicher Erkennung wird die gefundene Kombination für die weiteren Lesevorgänge verwendet.
7. Die SunSpec-Modellkette wird durchsucht und Modell 103 wird ausgelesen.

Die Modbus-API stellt Leseoperationen für Holding- und Input-Register bereit. SunSpec-Modell 103 ist das dreiphasige Wechselrichtermodell. [3] [4]

## Erfasste Telemetrie

| Feld | Bedeutung |
|---|---|
| `status` | Normalisierter Betriebsstatus, zum Beispiel `running`, `starting`, `idle` oder `error` |
| `sun_spec_model` | Erkannte SunSpec-Modellnummer, im getesteten Gerät `103` |
| `ac_l1_voltage` | Spannung L1 gegen N, sofern vom Gerät geliefert |
| `ac_l2_voltage` | Spannung L2 gegen N, sofern vom Gerät geliefert |
| `ac_l3_voltage` | Spannung L3 gegen N, sofern vom Gerät geliefert |
| `ac_l1_current` | Strom L1 |
| `ac_l2_current` | Strom L2 |
| `ac_l3_current` | Strom L3 |
| `ac_total_power` | Gemessene gesamte AC-Wirkleistung in W |
| `ac_total_power_kw` | Derselbe gemessene Gesamtwert in kW für eine verständlichere App-Anzeige |
| `ac_l1_power` | Geschätzte Leistung L1, Gesamtleistung geteilt durch 3 |
| `ac_l2_power` | Geschätzte Leistung L2, Gesamtleistung geteilt durch 3 |
| `ac_l3_power` | Geschätzte Leistung L3, Gesamtleistung geteilt durch 3 |
| `ac_frequency` | Netzfrequenz |
| `ac_power_apparent` | Scheinleistung |
| `ac_power_reactive` | Blindleistung |
| `ac_power_factor` | Leistungsfaktor |
| `ac_energy_total` | Kumulierte AC-Energie aus dem SunSpec-Feld `WH` in Wh |
| `ac_energy_total_kwh` | Derselbe kumulierte Energiezähler in kWh, entsprechend der SMA-Anzeige Total Yield |
| `dc_voltage` | DC-Spannung |
| `dc_current` | DC-Strom |
| `dc_power` | DC-Leistung |
| `inverter_temperature` | Bevorzugt Kühlkörpertemperatur, ansonsten Gehäusetemperatur |

## Wichtige Einschränkung bei den Phasenleistungen

SunSpec-Modell 103 stellt die gesamte AC-Wirkleistung `W` bereit, aber keine unabhängigen Wirkleistungen für L1, L2 und L3. Deshalb werden die drei Phasenwerte wie folgt berechnet:

```text
ac_l1_power = ac_total_power / 3
ac_l2_power = ac_total_power / 3
ac_l3_power = ac_total_power / 3
```

Der verbindliche Messwert ist `ac_total_power` beziehungsweise `ac_total_power_kw`. Die Phasenwerte sind nur Schätzwerte und dürfen nicht zur Unsymmetrieanalyse verwendet werden. [4]

## Statusabbildung

Die SunSpec-Betriebszustände werden wie folgt auf den Blueprint-Status abgebildet:

| SunSpec `St` | Blueprint-Status |
|---:|---|
| 1, 2, 6, 8 | `idle` |
| 3 | `starting` |
| 4 | `running` |
| 5 | `throttled` |
| 7 | `error` |

## Alarme

Der Blueprint definiert folgende Alarme:

- `communication_failed`: Die Modbus-Kommunikation oder das Auslesen ist fehlgeschlagen.
- `unsupported_device`: Es wurde kein SunSpec-Modell 103 gefunden.
- `not_configured`: Für ältere Installationen beziehungsweise historische Zustände, falls die Verbindung nicht konfiguriert wurde.

## Verhalten bei Kommunikationsfehlern

Der Code verhindert, dass ein fehlendes SunSpec-Layout weitere Lua-Fehler verursacht. Wenn die Verbindung oder die Modell-Erkennung fehlschlägt:

- wird der Fehler protokolliert,
- wird der Client zurückgesetzt,
- wird ein Kommunikationsalarm gesendet,
- wird bei der nächsten Ausführung erneut verbunden.

Fehlercodes ohne numerischen Wert werden sicher behandelt und nicht an `err_to_str` weitergereicht.

## Upload-Checkliste

1. `DEVICE_HOST` in `main.lua` auf die erreichbare SMA-IP setzen.
2. Prüfen, dass TCP-Port 502 erreichbar und Modbus TCP am SMA aktiviert ist.
3. `manifest.yml` und `main.lua` im selben Blueprint-Verzeichnis ablegen.
4. Den Blueprint dem Virtual UCM des Enapter Gateways zuweisen.
5. Den Blueprint hochladen.
6. Im Log nach `SunSpec connection ready` suchen.
7. Danach prüfen, ob Telemetrie mit `status: "running"` oder dem tatsächlichen Betriebsstatus eintrifft.

## Sicherheit und Umfang

Der Blueprint ist read-only. Er schreibt keine Register und führt keine Steuerbefehle am Wechselrichter aus. Das SMA-Webpasswort wird nicht im Blueprint gespeichert und nicht an die Modbus-Verbindung übertragen.

Die Tagesenergie wird nicht separat berechnet. Ausgelesen wird die kumulierte AC-Energie aus dem SunSpec-Feld `WH`.

## Referenzen

[1] Validierungslog des Projekts, 9. September 2026, erfolgreiche SunSpec-Erkennung und laufende Telemetrie.

[2] Enapter Handbook, *Universal Communication Modules*, Abschnitt `ENP-VIRTUAL`, https://dev-handbook.enapter.com/modules/modules.html

[3] Enapter Developer Toolkit, *Modbus TCP*, https://developers.enapter.com/docs/reference/vucm/modbustcp

[4] SunSpec Models Repository, *Model 103, Inverter Three Phase*, https://raw.githubusercontent.com/sunspec/models/master/json/model_103.json









