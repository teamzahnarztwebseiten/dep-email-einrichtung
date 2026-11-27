# Prüft einrichtung\Mail-einrichten.bat unter echtem Windows (cmd.exe), ohne Gerät:
# adb und curl werden durch ein nachgestelltes Programm ersetzt (Fake.cs), das jeden
# Aufruf mitschreibt. So wird geprüft, dass die Batch-Datei dieselben Befehle mit
# denselben Werten absetzt wie DEP-Mail-Einrichtung.ps1, auch bei Sonderzeichen im Passwort.
$ErrorActionPreference = 'Stop'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Bat  = Join-Path $Repo 'einrichtung\Mail-einrichten.bat'
$Base = Join-Path $env:TEMP ('battest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Base | Out-Null
$FakeExe = Join-Path $Base 'fake.exe'
Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'Fake.cs')) -OutputAssembly $FakeExe -OutputType ConsoleApplication
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Fehler = 0
$T = "`t"

$ACT = 'de.dentaleyepad.mail/net.thunderbird.app.common.provisioning.DepProvisioningActivity'
$DEVICES_1 = "List of devices attached`nABC123${T}device`n"
$LISTE_LEER = '{"data":[],"errors":null,"messages":null,"metadata":{},"status":1,"warnings":null}'
$LISTE_DA   = '{"data":[{"email":"dentaleyepad-31528@dentaleyepad.net","login":"dentaleyepad-31528@dentaleyepad.net","diskquota":"1024"}],"errors":null,"status":1}'

function New-Fall([string]$Name, [hashtable]$Cfg, [string]$AdbRegeln, [string]$CurlRegeln, [switch]$OhneApk, [switch]$OhneCfg) {
    $d = Join-Path $Base $Name
    New-Item -ItemType Directory -Path $d, (Join-Path $d 'apk'), (Join-Path $d 'fake') | Out-Null
    Copy-Item $Bat $d
    if (-not $OhneApk) { [IO.File]::WriteAllText((Join-Path $d 'apk\dep-mail.apk'), 'x') }
    if (-not $OhneCfg) { [IO.File]::WriteAllText((Join-Path $d 'mail-einstellungen.json'), ($Cfg | ConvertTo-Json), $Utf8) }
    Copy-Item $FakeExe (Join-Path $d 'fake\adb.exe')
    Copy-Item $FakeExe (Join-Path $d 'fake\curl.exe')
    [IO.File]::WriteAllText((Join-Path $d 'fake\adb.regeln'), $AdbRegeln, $Utf8)
    [IO.File]::WriteAllText((Join-Path $d 'fake\curl.regeln'), $CurlRegeln, $Utf8)
    return $d
}

function Invoke-Fall([string]$Dir, [string]$BatArgs) {
    $env:DEP_FAKE_DIR = Join-Path $Dir 'fake'
    $env:DEP_ADB = Join-Path $Dir 'fake\adb.exe'
    $env:DEP_CURL = Join-Path $Dir 'fake\curl.exe'
    $runner = Join-Path $Dir 'lauf.cmd'
    $out = Join-Path $Dir 'ausgabe.txt'
    [IO.File]::WriteAllText($runner, "@echo off`r`ncall `"$Dir\Mail-einrichten.bat`" $BatArgs <nul >`"$out`" 2>&1`r`nexit /b %errorlevel%`r`n", [Text.Encoding]::ASCII)
    & cmd.exe /d /c $runner
    $code = $LASTEXITCODE
    $log = Join-Path $Dir 'fake\aufrufe.log'
    $calls = @()
    if (Test-Path $log) { $calls = @([IO.File]::ReadAllLines($log, $Utf8)) }
    $text = [IO.File]::ReadAllText($out, $Utf8)
    Write-Host "----- Ausgabe ($code) -----"; Write-Host $text
    Write-Host '----- Aufrufe -----'; $calls | ForEach-Object { Write-Host $_ }
    return [pscustomobject]@{ Code = $code; Text = $text; Calls = $calls; Dir = $Dir }
}

function Check([string]$Was, [bool]$Ok) {
    if ($Ok) { Write-Host "  [OK]     $Was" } else { Write-Host "  [FEHLER] $Was"; $script:Fehler++ }
}
function Hat-Aufruf($r, [string]$Zeile) { return @($r.Calls | Where-Object { $_ -ceq $Zeile }).Count -gt 0 }
function Hat-Teil($r, [string]$Teil) { return @($r.Calls | Where-Object { $_.Contains($Teil) }).Count -gt 0 }

function Adb-Regeln([string]$Devices, [string]$Pakete, [string]$Ergebnis) {
    return "? devices`n$Devices`n? pm list packages`n$Pakete`n? install -r -g`nPerforming Streamed Install`nSuccess`n? am start`nStarting: Intent { act=de.dentaleyepad.mail.EINRICHTEN cmp=$ACT (has extras) }`nStatus: ok`n? logcat -d`n--------- beginning of main`n11-27 13:00:00.000  1234  1234 I DepEinrichtung: $Ergebnis`n"
}
function Curl-Regeln([string]$Liste, [string]$Anlegen) {
    return "? --version`ncurl 8.0`n? /list_pops`n$Liste`n? /add_pop`n$Anlegen`n"
}

# ---------------------------------------------------------------------------
Write-Host '== 1: neues Postfach, App nicht auf dem Gerät, Sonderzeichen im Passwort =='
$cfg = [ordered]@{
    _hinweis = 'Test'; server = 'mail.dentaleyepad.net'; adressMuster = 'dentaleyepad-{NR}@dentaleyepad.net'; kontoName = 'dentaleyepad {NR}'
    passwortRegel1 = 'Ab$(x)/{NR}''%&^!;<>|=,~'; passwortRegel2 = '$(/{NR}'
    cpanelServer = 'cp.example.invalid'; cpanelBenutzer = 'benutzer'; cpanelToken = 'TOKEN123'; postfachGroesseMB = 2048
}
$d = New-Fall 'f1' $cfg (Adb-Regeln $DEVICES_1 'package:de.dentaleyepad.mailx' 'ERGEBNIS OK angelegt') (Curl-Regeln $LISTE_LEER '{"data":"x","errors":null,"status":1}')
$r = Invoke-Fall $d '31528'
$pw = 'Ab$(x)/31528''%&^!;<>|=,~'
Check 'Rückgabewert 0' ($r.Code -eq 0)
Check 'Meldung Fertig' ($r.Text.Contains('Fertig. Konto dentaleyepad-31528@dentaleyepad.net ist eingerichtet.'))
Check 'Meldung Postfach angelegt' ($r.Text.Contains('Postfach im cPanel neu angelegt.'))
Check 'Umlaute kommen als UTF-8 an' ($r.Text.Contains('Anmeldung am Mailserver wird geprüft'))
Check 'cPanel list_pops mit Filter und Token' (Hat-Teil $r "curl${T}-sS${T}-f${T}--max-time${T}60${T}-G${T}https://cp.example.invalid:2083/execute/Email/list_pops${T}-H${T}Authorization: cpanel benutzer:TOKEN123${T}--data-urlencode${T}regex=^dentaleyepad-31528@dentaleyepad\.net`$${T}-o${T}")
Check 'cPanel add_pop mit unverändertem Passwort' (Hat-Teil $r "/add_pop${T}-H${T}Authorization: cpanel benutzer:TOKEN123${T}--data-urlencode${T}email=dentaleyepad-31528${T}--data-urlencode${T}domain=dentaleyepad.net${T}--data-urlencode${T}password=$pw${T}--data-urlencode${T}quota=2048${T}--data-urlencode${T}send_welcome_email=0${T}-o${T}")
Check 'App wird installiert (install -r -g)' (Hat-Aufruf $r "adb${T}install${T}-r${T}-g${T}$d\apk\dep-mail.apk")
$erwartet = "am start -W -a de.dentaleyepad.mail.EINRICHTEN -n $ACT --es email 'dentaleyepad-31528@dentaleyepad.net' --es host 'mail.dentaleyepad.net' --es password 'Ab`$(x)/31528'\''%&^!;<>|=,~' --es password2 '`$(/31528' --es name 'dentaleyepad 31528'"
Check 'Konto-Befehl an die App stimmt Zeichen für Zeichen' (Hat-Aufruf $r "adb${T}shell${T}$erwartet")
Check 'logcat wird vorher geleert' (Hat-Aufruf $r "adb${T}logcat${T}-c")
$csvBytes = [IO.File]::ReadAllBytes((Join-Path $d 'mail-protokoll.csv'))
$csv = [IO.File]::ReadAllText((Join-Path $d 'mail-protokoll.csv'), $Utf8)
Check 'Protokoll beginnt mit BOM' ($csvBytes[0] -eq 0xEF -and $csvBytes[1] -eq 0xBB -and $csvBytes[2] -eq 0xBF)
Check 'Protokoll hat Kopfzeile' ($csv.Contains('"Datum";"Seriennummer";"EMail";"Ergebnis";"Regel";"Hinweis"'))
Check 'Protokoll hat die Zeile' ($csv.Contains('";"31528";"dentaleyepad-31528@dentaleyepad.net";"OK";"1";"angelegt"'))
Check 'Protokoll enthält kein Passwort' (-not $csv.Contains('Ab$'))
Check 'Ausgabe enthält kein Passwort und kein Token' (-not $r.Text.Contains('Ab$') -and -not $r.Text.Contains('TOKEN123'))
$rows = @(Import-Csv -Path (Join-Path $d 'mail-protokoll.csv') -Delimiter ';' -Encoding UTF8)
Check 'Protokoll ist als CSV lesbar' ($rows.Count -eq 1 -and $rows[0].Seriennummer -eq '31528' -and $rows[0].Ergebnis -eq 'OK')

# ---------------------------------------------------------------------------
Write-Host '== 2: Postfach gibt es schon, App schon da, alte Passwort-Regel passt =='
$cfg2 = [ordered]@{ server = 'mail.dentaleyepad.net'; adressMuster = 'dentaleyepad-{NR}@dentaleyepad.net'; kontoName = ''
    passwortRegel1 = 'neu-{NR}'; passwortRegel2 = 'alt-{NR}'; cpanelBenutzer = 'benutzer'; cpanelToken = 'TOKEN123' }
$d = New-Fall 'f2' $cfg2 (Adb-Regeln $DEVICES_1 "package:de.dentaleyepad.mail" 'ERGEBNIS OK_PASSWORT2') (Curl-Regeln $LISTE_DA 'DARF-NICHT-AUFGERUFEN-WERDEN') -OhneApk
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 0' ($r.Code -eq 0)
Check 'Meldung: Postfach gibt es schon' ($r.Text.Contains('Postfach gibt es schon im cPanel.'))
Check 'kein add_pop' (-not (Hat-Teil $r '/add_pop'))
Check 'Standard-Server dentaleyepad.net' (Hat-Teil $r 'https://dentaleyepad.net:2083/execute/Email/list_pops')
Check 'Installation übersprungen' ($r.Text.Contains('Installation wird übersprungen') -and -not (Hat-Teil $r "adb${T}install"))
Check 'Befehl ohne Kontoname' (Hat-Aufruf $r "adb${T}shell${T}am start -W -a de.dentaleyepad.mail.EINRICHTEN -n $ACT --es email 'dentaleyepad-31528@dentaleyepad.net' --es host 'mail.dentaleyepad.net' --es password 'neu-31528' --es password2 'alt-31528'")
Check 'Meldung alte Regel' ($r.Text.Contains('nur mit der ALTEN Passwort-Regel'))
Check 'Protokoll: Regel 2' ([IO.File]::ReadAllText((Join-Path $d 'mail-protokoll.csv'), $Utf8).Contains('"OK_PASSWORT2";"2";""'))

# ---------------------------------------------------------------------------
Write-Host '== 3: kein Token eingetragen, Anmeldung abgelehnt =='
$cfg3 = [ordered]@{ server = 'mail.dentaleyepad.net'; adressMuster = 'dentaleyepad-{NR}@dentaleyepad.net'; kontoName = 'dentaleyepad {NR}'
    passwortRegel1 = 'neu-{NR}'; passwortRegel2 = ''; cpanelBenutzer = 'HIER-CPANEL-BENUTZERNAME'; cpanelToken = 'HIER-API-TOKEN' }
$d = New-Fall 'f3' $cfg3 (Adb-Regeln $DEVICES_1 "package:de.dentaleyepad.mail" 'ERGEBNIS FEHLER_ANMELDUNG Benutzer "x" abgelehnt') ''
$r = Invoke-Fall $d '00042'
Check 'Rückgabewert 1' ($r.Code -eq 1)
Check 'Hinweis: kein Token' ($r.Text.Contains('Postfach wird nicht automatisch angelegt (kein cPanel-Token eingetragen).'))
Check 'kein curl-Aufruf' (-not (Hat-Teil $r 'curl'))
Check 'Befehl ohne password2' (Hat-Aufruf $r "adb${T}shell${T}am start -W -a de.dentaleyepad.mail.EINRICHTEN -n $ACT --es email 'dentaleyepad-00042@dentaleyepad.net' --es host 'mail.dentaleyepad.net' --es password 'neu-00042' --es name 'dentaleyepad 00042'")
Check 'Meldung Anmeldung abgelehnt' ($r.Text.Contains('Anmeldung abgelehnt. Gibt es das Postfach, und stimmen die Passwort-Regeln? (Benutzer "x" abgelehnt)'))
$rows = @(Import-Csv -Path (Join-Path $d 'mail-protokoll.csv') -Delimiter ';' -Encoding UTF8)
Check 'Protokoll: Hinweis mit Anführungszeichen bleibt lesbar' ($rows.Count -eq 1 -and $rows[0].Hinweis -eq 'Benutzer "x" abgelehnt' -and $rows[0].Ergebnis -eq 'FEHLER_ANMELDUNG')

# ---------------------------------------------------------------------------
Write-Host '== 4: kein Gerät angeschlossen =='
$d = New-Fall 'f4' $cfg2 (Adb-Regeln "List of devices attached`n" '' 'ERGEBNIS OK') (Curl-Regeln $LISTE_DA 'x')
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1' ($r.Code -eq 1)
Check 'Meldung' ($r.Text.Contains('Es muss genau ein Gerät per USB verbunden und freigegeben sein (gefunden: 0).'))
Check 'nichts am cPanel oder Gerät geändert' (-not (Hat-Teil $r 'curl') -and -not (Hat-Teil $r 'am start'))

Write-Host '== 5: zwei Geräte, eines nicht freigegeben zählt nicht =='
$d = New-Fall 'f5' $cfg2 (Adb-Regeln "List of devices attached`nABC${T}device`nDEF${T}unauthorized`nGHI${T}device`n" '' 'ERGEBNIS OK') (Curl-Regeln $LISTE_DA 'x')
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1 und Zahl 2' ($r.Code -eq 1 -and $r.Text.Contains('(gefunden: 2)'))

Write-Host '== 6: ungültige Seriennummer =='
foreach ($nr in @('1234', '123456', '12a45', '"12 45"')) {
    $d = New-Fall ("f6-" + ($nr -replace '[^0-9a-z]', '_')) $cfg2 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') (Curl-Regeln $LISTE_DA 'x')
    $r = Invoke-Fall $d $nr
    Check "Rückgabewert 1 bei $nr, kein Aufruf" ($r.Code -eq 1 -and $r.Text.Contains('genau fünf Ziffern') -and $r.Calls.Count -eq 0)
}

Write-Host '== 7: Anführungszeichen in der Passwort-Regel wird abgelehnt =='
$cfg7 = [ordered]@{ server = 'mail.dentaleyepad.net'; adressMuster = 'dentaleyepad-{NR}@dentaleyepad.net'; passwortRegel1 = 'a"b-{NR}'; passwortRegel2 = '' }
$d = New-Fall 'f7' $cfg7 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') ''
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1, Meldung, kein Aufruf' ($r.Code -eq 1 -and $r.Text.Contains('kein Anführungszeichen') -and $r.Calls.Count -eq 0)

Write-Host '== 8: cPanel nicht erreichbar =='
$d = New-Fall 'f8' $cfg2 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') "? --version`ncurl 8.0`n? /list_pops`n#exit 22`n"
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1, Meldung, Gerät unberührt' ($r.Code -eq 1 -and $r.Text.Contains('cPanel nicht erreichbar oder Token falsch') -and -not (Hat-Teil $r 'am start') -and -not (Hat-Teil $r 'pm list'))

Write-Host '== 9: add_pop meldet "already exists" =='
$d = New-Fall 'f9' $cfg2 (Adb-Regeln $DEVICES_1 "package:de.dentaleyepad.mail" 'ERGEBNIS VORHANDEN') (Curl-Regeln $LISTE_LEER '{"data":null,"errors":["The account dentaleyepad-31528@dentaleyepad.net already exists!"],"status":0}')
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 0, als vorhanden gewertet' ($r.Code -eq 0 -and $r.Text.Contains('Postfach gibt es schon im cPanel.') -and $r.Text.Contains('war auf dem Gerät schon eingerichtet'))

Write-Host '== 10: cPanel lehnt das Anlegen ab =='
$d = New-Fall 'f10' $cfg2 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') (Curl-Regeln $LISTE_LEER '{"data":null,"errors":["The password is too weak."],"status":0}')
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1, Grund wird gezeigt, Gerät unberührt' ($r.Code -eq 1 -and $r.Text.Contains('Postfach konnte nicht angelegt werden.') -and $r.Text.Contains('too weak') -and -not (Hat-Teil $r 'am start'))

Write-Host '== 11: Einstellungen fehlen / App fehlt und keine APK =='
$d = New-Fall 'f11a' $cfg2 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') '' -OhneCfg
$r = Invoke-Fall $d '31528'
Check 'Einstellungen fehlen' ($r.Code -eq 1 -and $r.Text.Contains('mail-einstellungen.json fehlt'))
$d = New-Fall 'f11b' $cfg3 (Adb-Regeln $DEVICES_1 '' 'ERGEBNIS OK') '' -OhneApk
$r = Invoke-Fall $d '31528'
Check 'keine APK' ($r.Code -eq 1 -and $r.Text.Contains('liegt keine APK') -and -not (Hat-Teil $r 'am start'))

Write-Host '== 12: App startet nicht =='
$adb12 = "? devices`n$DEVICES_1`n? pm list packages`npackage:de.dentaleyepad.mail`n? am start`nSecurity exception: Permission Denial`n"
$d = New-Fall 'f12' $cfg3 $adb12 ''
$r = Invoke-Fall $d '31528'
Check 'Rückgabewert 1, Meldung' ($r.Code -eq 1 -and $r.Text.Contains('App konnte nicht gestartet werden: Security exception: Permission Denial'))

Write-Host ''
if ($script:Fehler -gt 0) { throw "$($script:Fehler) Prüfung(en) fehlgeschlagen" }
Write-Host 'Alle Prüfungen bestanden.'
