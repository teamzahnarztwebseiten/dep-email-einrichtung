# DEP Mail – dentaleyepad-Mail-App

Eigene Mail-App für das dentaleyepad (DEP 4). Grundlage ist **Thunderbird für Android 25.0**
(Apache-2.0, Quelle: https://github.com/thunderbird/thunderbird-android, Tag `THUNDERBIRD_25_0`).
Sie ersetzt Microsoft Outlook auf den Geräten. Das Konto wird beim Einrichten per USB automatisch
angelegt, am Gerät muss nichts eingegeben werden.

## Was gegenüber Thunderbird geändert ist

| Was | Wo |
|---|---|
| Paketname `de.dentaleyepad.mail`, App-Name „DEP Mail“ (auch im Debug-Build ohne Suffix) | `app-thunderbird/build.gradle.kts`, `app-thunderbird/src/*/res/values/strings.xml` |
| Automatische Konto-Einrichtung per ADB | `app-common/.../provisioning/DepProvisioningActivity.kt`, Eintrag in `app-common/src/main/AndroidManifest.xml` |
| Schlanker Build in GitHub Actions (APK als Artefakt `dep-mail-apk`), Upstream-Workflows entfernt | `.github/workflows/dep-mail-apk.yml` |
| Einrichtungs-Skript für den PC (Probelauf) | `einrichtung/` |

## Automatische Einrichtung

Das Einrichtungsprogramm am PC startet in der App eine geschützte Einrichtungs-Seite und übergibt
Adresse und Passwort:

```
adb shell am start -W -a de.dentaleyepad.mail.EINRICHTEN \
  -n de.dentaleyepad.mail/net.thunderbird.app.common.provisioning.DepProvisioningActivity \
  --es email dentaleyepad-12345@dentaleyepad.net --es password '<Regel 1>' --es password2 '<Regel 2>'
```

- Nur die ADB-Shell darf diese Seite starten (Berechtigung `android.permission.DUMP`).
- Die App meldet sich zuerst mit `password` am IMAP-Server an. Klappt das nicht, probiert sie `password2`.
  Danach prüft sie den SMTP-Server und legt das Konto an.
- Server: `mail.dentaleyepad.net`, IMAP 993 und SMTP 465, beide SSL/TLS, Benutzername = Adresse.
- Ergebnis im Logcat (`adb logcat -d -s DepEinrichtung:I`), Zeile `ERGEBNIS <Status> <Detail>`.
  Status: `OK`, `OK_PASSWORT2`, `VORHANDEN`, `FEHLER_ANMELDUNG`, `FEHLER_NETZWERK`,
  `FEHLER_ZERTIFIKAT`, `FEHLER_EINGABE`, `FEHLER`. Passwörter werden nie protokolliert.

## Probelauf am PC

1. APK aus GitHub Actions laden (Workflow „DEP Mail APK bauen“, Artefakt `dep-mail-apk`) und in `einrichtung/apk/` legen.
2. `adb.exe` mit Zubehör nach `einrichtung/platform-tools/` kopieren.
3. `mail-einstellungen.beispiel.json` als `mail-einstellungen.json` kopieren und die zwei Passwort-Regeln eintragen.
   Diese Datei gehört **nicht** ins Repository.
4. Gerät per USB anschließen (USB-Debugging an, WLAN verbunden), `DEP-Mail-Einrichtung.cmd` doppelklicken, Seriennummer eingeben.
5. Ergebnis steht im Fenster und in `mail-protokoll.csv` (ohne Passwörter).

## Offen

- Vereinfachte Oberfläche im doctorseyes-Stil (nur Posteingang und Senden), eigenes Icon.
- Name und Logo von Thunderbird vollständig entfernen (Markenrecht von Mozilla).
- Postfächer automatisch per cPanel-Schnittstelle (`Email::add_pop`) anlegen.
- Übernahme als Schritt in das gemeinsame Einrichtungsprogramm (DEP-Einrichtung).
- Eigener Signierschlüssel statt Debug-Schlüssel.
