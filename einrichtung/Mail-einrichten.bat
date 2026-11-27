@echo off
rem ===========================================================================
rem  Mail-einrichten.bat - richtet "DEP Mail" per USB ein, als reine Batch-Datei.
rem
rem  Aufruf:  Mail-einrichten.bat 31528      (Seriennummer gleich mitgeben)
rem  oder:    Doppelklick, dann fragt die Datei nach der Seriennummer.
rem
rem  Ergebnis fuer andere Batch-Dateien:  errorlevel 0 = eingerichtet, 1 = Fehler
rem
rem  Der Ablauf ist derselbe wie in DEP-Mail-Einrichtung.ps1. Diese Datei muss als
rem  UTF-8 OHNE BOM mit Windows-Zeilenenden (CRLF) gespeichert bleiben.
rem ===========================================================================
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT=%~dp0"
set "PKG=de.dentaleyepad.mail"
set "ACTION=de.dentaleyepad.mail.EINRICHTEN"
set "ACTIVITY=%PKG%/net.thunderbird.app.common.provisioning.DepProvisioningActivity"
set "LOG_TAG=DepEinrichtung"
set "CFG=%ROOT%mail-einstellungen.json"
set "CSV=%ROOT%mail-protokoll.csv"
set "APKDIR=%ROOT%apk"
set "TMPF=%TEMP%\dep-mail-%RANDOM%-%RANDOM%.tmp"
set "NR=%~1"
set "INTERAKTIV="
if "%~1"=="" set "INTERAKTIV=1"
set "RC=1"

rem Die Programme adb und curl. Nur für Tests lassen sie sich von außen ersetzen.
if not defined DEP_ADB set "DEP_ADB=%ROOT%platform-tools\adb.exe"
if not defined DEP_CURL set "DEP_CURL=curl.exe"

rem Farben für die Meldungen (Windows 10/11)
set "ESC="
for /f %%e in ('echo prompt $E^| cmd') do set "ESC=%%e"

rem ---------------------------------------------------------------------------
rem Einstellungen lesen. Batch kann kein JSON lesen, deshalb liest eine einzige
rem PowerShell-Zeile die Datei und gibt jede Zeile als Name=:Wert zurück.
rem Hier ist die verzögerte Auswertung noch aus, damit Sonderzeichen in den
rem Passwort-Regeln (z. B. ! % ^ &) unverändert bleiben.
rem ---------------------------------------------------------------------------
set "DEP_CFG=%CFG%"
if exist "%CFG%" for /f "usebackq tokens=1,* delims==" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$j = Get-Content -Raw -Encoding UTF8 -LiteralPath $env:DEP_CFG | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $p.Name + '=:' + $p.Value }"`) do set "CFG_%%A=%%B"

setlocal EnableDelayedExpansion
for %%K in (server adressMuster kontoName passwortRegel1 passwortRegel2 cpanelServer cpanelBenutzer cpanelToken postfachGroesseMB) do if defined CFG_%%K set "CFG_%%K=!CFG_%%K:~1!"

if not exist "!DEP_ADB!" (
    set "MSG=adb.exe fehlt im Ordner !ROOT!platform-tools."
    goto :fehler
)
if not exist "!CFG!" (
    set "MSG=mail-einstellungen.json fehlt. Bitte die Vorlage mail-einstellungen.beispiel.json kopieren und ausfüllen."
    goto :fehler
)
for %%K in (server adressMuster passwortRegel1) do if not defined CFG_%%K (
    set "MSG=In mail-einstellungen.json fehlt der Eintrag '%%K' (oder die Datei ist nicht lesbar)."
    goto :fehler
)
if "!CFG_passwortRegel1:{NR}=!"=="!CFG_passwortRegel1!" (
    set "MSG=passwortRegel1 enthält kein {NR}."
    goto :fehler
)
rem Ein Anführungszeichen oder ein \ am Ende lässt sich in Batch nicht sicher
rem an adb und curl weitergeben. Lieber abbrechen als ein falsches Passwort setzen.
set CFG_passwortRegel 2>nul | findstr /l /c:"\"^" >nul
if not errorlevel 1 (
    set "MSG=Die Passwort-Regeln dürfen kein Anführungszeichen enthalten. Dafür bitte DEP-Mail-Einrichtung.cmd verwenden."
    goto :fehler
)
set "ENDE1=!CFG_passwortRegel1:~-1!"
set "ENDE2="
if defined CFG_passwortRegel2 set "ENDE2=!CFG_passwortRegel2:~-1!"
if "!ENDE1!"=="\" goto :regel_ende_fehler
if "!ENDE2!"=="\" goto :regel_ende_fehler
goto :regel_ok
:regel_ende_fehler
set "MSG=Die Passwort-Regeln dürfen nicht mit \ enden. Dafür bitte DEP-Mail-Einrichtung.cmd verwenden."
goto :fehler
:regel_ok

rem ---------------------------------------------------------------------------
rem 1. Seriennummer
rem ---------------------------------------------------------------------------
if not defined NR goto :nr_fragen
call :nr_gueltig
if errorlevel 1 (
    set "MSG=Die Seriennummer muss aus genau fünf Ziffern bestehen."
    goto :fehler
)
goto :nr_ok
:nr_fragen
set /a FRAGEN=0
:nr_fragen_nochmal
set /a FRAGEN+=1
if !FRAGEN! gtr 20 (
    set "MSG=Keine gültige Seriennummer eingegeben."
    goto :fehler
)
set "NR="
set /p "NR=Fünfstellige Seriennummer des Geräts: "
call :nr_gueltig
if errorlevel 1 goto :nr_fragen_nochmal
:nr_ok

set "EMAIL=!CFG_adressMuster:{NR}=%NR%!"
set "KONTONAME="
if defined CFG_kontoName set "KONTONAME=!CFG_kontoName:{NR}=%NR%!"
set "PW1=!CFG_passwortRegel1:{NR}=%NR%!"
set "PW2="
if defined CFG_passwortRegel2 set "PW2=!CFG_passwortRegel2:{NR}=%NR%!"
echo Postfach: !EMAIL!

rem ---------------------------------------------------------------------------
rem 2. Genau ein Gerät per USB?
rem ---------------------------------------------------------------------------
"!DEP_ADB!" devices > "!TMPF!" 2>nul
set /a GERAETE=0
for /f "usebackq tokens=1,2" %%a in ("!TMPF!") do if "%%b"=="device" set /a GERAETE+=1
if not !GERAETE! equ 1 (
    set "MSG=Es muss genau ein Gerät per USB verbunden und freigegeben sein (gefunden: !GERAETE!)."
    goto :fehler
)

rem ---------------------------------------------------------------------------
rem 3. Postfach im cPanel prüfen und bei Bedarf anlegen (UAPI, mit API-Token)
rem ---------------------------------------------------------------------------
set "CP=ABFRAGEN"
if not defined CFG_cpanelToken set "CP=UEBERSPRUNGEN"
if not defined CFG_cpanelBenutzer set "CP=UEBERSPRUNGEN"
if defined CFG_cpanelToken if /i "!CFG_cpanelToken:~0,5!"=="HIER-" set "CP=UEBERSPRUNGEN"
if "!CP!"=="UEBERSPRUNGEN" goto :cpanel_fertig

"!DEP_CURL!" --version >nul 2>&1
if errorlevel 1 (
    set "MSG=curl.exe wurde nicht gefunden. Es gehört zu Windows 10 (ab 1803) und Windows 11."
    goto :fehler
)
if not defined CFG_cpanelServer set "CFG_cpanelServer=dentaleyepad.net"
if not defined CFG_postfachGroesseMB set "CFG_postfachGroesseMB=1024"
for /f "tokens=1,2 delims=@" %%a in ("!EMAIL!") do (
    set "MAIL_USER=%%a"
    set "MAIL_DOMAIN=%%b"
)
set "CP_URL=https://!CFG_cpanelServer!:2083/execute/Email"
set "CP_AUTH=Authorization: cpanel !CFG_cpanelBenutzer!:!CFG_cpanelToken!"
rem Suchmuster ^adresse$ . Das ^ steht in einer eigenen Zeile ohne Ausrufezeichen,
rem sonst würde Batch es verschlucken.
set "RX_ANFANG=^"
set "EMAIL_RX=!EMAIL:.=\.!"

rem Erst nachsehen, ob es das Postfach schon gibt (Email::list_pops mit Filter)
"!DEP_CURL!" -sS -f --max-time 60 -G "!CP_URL!/list_pops" -H "!CP_AUTH!" --data-urlencode "regex=!RX_ANFANG!!EMAIL_RX!$" -o "!TMPF!" 2>"!TMPF!.err"
if errorlevel 1 goto :cpanel_nicht_erreichbar
findstr /r /c:"\"status\" *: *1" "!TMPF!" >nul
if errorlevel 1 goto :cpanel_anlegen
findstr /i /l /c:"\"!EMAIL!\"" "!TMPF!" >nul
if not errorlevel 1 (
    set "CP=VORHANDEN"
    goto :cpanel_fertig
)

:cpanel_anlegen
rem curl kodiert die Werte selbst (--data-urlencode), auch Sonderzeichen im Passwort.
"!DEP_CURL!" -sS -f --max-time 60 -G "!CP_URL!/add_pop" -H "!CP_AUTH!" --data-urlencode "email=!MAIL_USER!" --data-urlencode "domain=!MAIL_DOMAIN!" --data-urlencode "password=!PW1!" --data-urlencode "quota=!CFG_postfachGroesseMB!" --data-urlencode "send_welcome_email=0" -o "!TMPF!" 2>"!TMPF!.err"
if errorlevel 1 goto :cpanel_nicht_erreichbar
findstr /r /c:"\"status\" *: *1" "!TMPF!" >nul
if not errorlevel 1 (
    set "CP=ANGELEGT"
    goto :cpanel_fertig
)
findstr /i /l /c:"exist" "!TMPF!" >nul
if not errorlevel 1 (
    set "CP=VORHANDEN"
    goto :cpanel_fertig
)
set "AUS="
for /f "usebackq delims=" %%l in ("!TMPF!") do if not defined AUS set "AUS=%%l"
set "MSG=Postfach konnte nicht angelegt werden. cPanel: !AUS!"
goto :fehler

:cpanel_nicht_erreichbar
set "AUS="
for /f "usebackq delims=" %%l in ("!TMPF!.err") do if not defined AUS set "AUS=%%l"
set "MSG=Postfach konnte nicht angelegt werden. cPanel nicht erreichbar oder Token falsch: !AUS!"
goto :fehler

:cpanel_fertig
if "!CP!"=="ANGELEGT" (
    set "MSG=Postfach im cPanel neu angelegt."
    call :melde 92
)
if "!CP!"=="VORHANDEN" echo Postfach gibt es schon im cPanel.
if "!CP!"=="UEBERSPRUNGEN" (
    set "MSG=Postfach wird nicht automatisch angelegt (kein cPanel-Token eingetragen)."
    call :melde 93
)

rem ---------------------------------------------------------------------------
rem 4. App installieren, falls sie noch nicht auf dem Gerät ist (z. B. über MDMesh)
rem ---------------------------------------------------------------------------
"!DEP_ADB!" shell "pm list packages !PKG!" > "!TMPF!" 2>&1
rem Zeile für Zeile vergleichen: adb liefert Unix-Zeilenenden, damit kommt findstr /x nicht zurecht.
set "APP_DA="
for /f "usebackq delims=" %%l in ("!TMPF!") do if "%%l"=="package:!PKG!" set "APP_DA=1"
if defined APP_DA (
    echo App ist schon auf dem Gerät ^(z. B. über MDMesh^), Installation wird übersprungen.
    goto :app_da
)
set "APK="
for /f "delims=" %%f in ('dir /b /a-d /o-d "!APKDIR!\*.apk" 2^>nul') do if not defined APK set "APK=%%f"
if not defined APK (
    set "MSG=Die App ist nicht auf dem Gerät und im Ordner !APKDIR! liegt keine APK. Bitte zuerst über MDMesh verteilen oder die APK in den Ordner legen."
    goto :fehler
)
echo App wird installiert: !APK!
"!DEP_ADB!" install -r -g "!APKDIR!\!APK!" > "!TMPF!" 2>&1
set "INSTALL_RC=!errorlevel!"
findstr /l /c:"Success" "!TMPF!" >nul
if errorlevel 1 set "INSTALL_RC=1"
if not "!INSTALL_RC!"=="0" (
    set "AUS="
    for /f "usebackq delims=" %%l in ("!TMPF!") do set "AUS=!AUS! %%l"
    set "MSG=Installation fehlgeschlagen:!AUS!"
    goto :fehler
)
:app_da

rem ---------------------------------------------------------------------------
rem 5. Konto in der App einrichten und auf das Ergebnis im Logcat warten
rem    Die Werte stehen für die Shell auf dem Gerät in einfachen Anführungszeichen,
rem    damit Zeichen wie $ ( ) / unverändert ankommen.
rem ---------------------------------------------------------------------------
echo Konto wird eingerichtet, Anmeldung am Mailserver wird geprüft ...
"!DEP_ADB!" logcat -c >nul 2>&1

set "Q=!EMAIL:'='\''!"
set "BEFEHL=am start -W -a !ACTION! -n !ACTIVITY! --es email '!Q!'"
set "Q=!CFG_server:'='\''!"
set "BEFEHL=!BEFEHL! --es host '!Q!'"
set "Q=!PW1:'='\''!"
set "BEFEHL=!BEFEHL! --es password '!Q!'"
if defined PW2 (
    set "Q=!PW2:'='\''!"
    set "BEFEHL=!BEFEHL! --es password2 '!Q!'"
)
if defined KONTONAME (
    set "Q=!KONTONAME:'='\''!"
    set "BEFEHL=!BEFEHL! --es name '!Q!'"
)
"!DEP_ADB!" shell "!BEFEHL!" > "!TMPF!" 2>&1
set "STATUS="
set "DETAIL="
findstr /i /l /c:"Error" /c:"Exception" /c:"Security" "!TMPF!" >nul
if not errorlevel 1 (
    set "AUS="
    for /f "usebackq delims=" %%l in ("!TMPF!") do set "AUS=!AUS! %%l"
    set "STATUS=FEHLER"
    set "DETAIL=App konnte nicht gestartet werden:!AUS!"
    goto :ergebnis
)

rem Bis zu 90 Sekunden warten, alle 2 Sekunden nachsehen
set /a VERSUCH=0
:warte_auf_ergebnis
set /a VERSUCH+=1
ping -n 3 127.0.0.1 >nul
"!DEP_ADB!" logcat -d -s !LOG_TAG!:I > "!TMPF!" 2>nul
set "ZEILE="
for /f "usebackq delims=" %%l in (`findstr /l /c:"ERGEBNIS " "!TMPF!"`) do if not defined ZEILE set "ZEILE=%%l"
if defined ZEILE goto :ergebnis_lesen
if !VERSUCH! lss 45 goto :warte_auf_ergebnis
set "STATUS=FEHLER"
set "DETAIL=Kein Ergebnis nach 90 s"
goto :ergebnis

:ergebnis_lesen
set "REST=!ZEILE:*ERGEBNIS =!"
for /f "tokens=1,*" %%a in ("!REST!") do (
    set "STATUS=%%a"
    set "DETAIL=%%b"
)

:ergebnis
rem ---------------------------------------------------------------------------
rem 6. Ergebnis in mail-protokoll.csv schreiben (ohne Passwörter) und anzeigen
rem ---------------------------------------------------------------------------
set "REGEL="
if "!STATUS!"=="OK" set "REGEL=1"
if "!STATUS!"=="OK_PASSWORT2" set "REGEL=2"
set "HINWEIS="
if defined DETAIL set "HINWEIS=!DETAIL:"=""!"
set "DATUM=!date! !time:~0,5!"
if not exist "!CSV!" call :csv_anlegen
>>"!CSV!" echo "!DATUM!";"!NR!";"!EMAIL!";"!STATUS!";"!REGEL!";"!HINWEIS!"

set "FARBE=91"
set "MSG=Einrichtung fehlgeschlagen: !STATUS! !DETAIL!"
if "!STATUS!"=="OK" (
    set "RC=0"
    set "FARBE=92"
    set "MSG=Fertig. Konto !EMAIL! ist eingerichtet."
)
if "!STATUS!"=="OK_PASSWORT2" (
    set "RC=0"
    set "FARBE=93"
    set "MSG=Fertig. Konto !EMAIL! ist eingerichtet, aber nur mit der ALTEN Passwort-Regel. Das Postfach sollte auf die gültige Regel umgestellt werden."
)
if "!STATUS!"=="VORHANDEN" (
    set "RC=0"
    set "FARBE=92"
    set "MSG=Konto !EMAIL! war auf dem Gerät schon eingerichtet."
)
if "!STATUS!"=="FEHLER_ANMELDUNG" set "MSG=Anmeldung abgelehnt. Gibt es das Postfach, und stimmen die Passwort-Regeln? (!DETAIL!)"
if "!STATUS!"=="FEHLER_NETZWERK" set "MSG=Mailserver nicht erreichbar. Hat das Gerät Internet (WLAN)? (!DETAIL!)"
call :melde !FARBE!
goto :ende

:fehler
call :melde 91
set "RC=1"

:ende
del "!TMPF!" "!TMPF!.err" >nul 2>&1
if defined INTERAKTIV pause
exit /b !RC!

rem ===========================================================================
rem Unterprogramme
rem ===========================================================================

rem Zeigt den Text aus MSG in der Farbe %1 (91 rot, 92 grün, 93 gelb).
:melde
if defined ESC (echo(!ESC![%~1m!MSG!!ESC![0m) else echo(!MSG!
exit /b 0

rem Prüft, ob NR aus genau fünf Ziffern besteht (errorlevel 0 = ja).
:nr_gueltig
if not defined NR exit /b 1
if not "!NR:~5!"=="" exit /b 1
if "!NR:~4,1!"=="" exit /b 1
for /f "delims=0123456789" %%x in ("!NR!") do exit /b 1
exit /b 0

rem Legt mail-protokoll.csv mit Kopfzeile an. Die drei Bytes am Anfang (BOM)
rem braucht Excel, um Umlaute richtig zu zeigen; die kann Batch nicht selbst schreiben.
:csv_anlegen
set "DEP_CSV=!CSV!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[IO.File]::WriteAllBytes($env:DEP_CSV, [byte[]](0xEF,0xBB,0xBF))" >nul 2>&1
>>"!CSV!" echo "Datum";"Seriennummer";"EMail";"Ergebnis";"Regel";"Hinweis"
exit /b 0
