# DEP-Mail-Einrichtung (Probelauf): spielt die App "DEP Mail" per USB auf ein dentaleyepad
# und richtet das Postfach dentaleyepad-<Seriennummer>@dentaleyepad.net ohne Eingabe am Gerät ein.
#
# Start: DEP-Mail-Einrichtung.cmd (Doppelklick) oder mit Seriennummer:
#   DEP-Mail-Einrichtung.cmd 31528
#
# Fehlt das Postfach, legt das Programm es vorher im cPanel an (nur mit cPanel-Token in mail-einstellungen.json).
#
# Benötigt: Windows 10/11 (Windows PowerShell 5.1), adb.exe im Ordner platform-tools,
# die APK im Ordner apk und die Datei mail-einstellungen.json (Vorlage: mail-einstellungen.beispiel.json).
#
# Später wird dieser Ablauf ein Schritt im gemeinsamen Einrichtungsprogramm (DEP-Einrichtung).
# Die Funktionen sind deshalb so geschrieben, dass sie dort übernommen werden können.
# Die Datei muss als UTF-8 MIT BOM gespeichert bleiben, sonst zeigt PowerShell 5.1 Umlaute falsch an.

param([string]$Seriennummer = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PKG      = 'de.dentaleyepad.mail'
$ACTION   = 'de.dentaleyepad.mail.EINRICHTEN'
$ACTIVITY = "$PKG/net.thunderbird.app.common.provisioning.DepProvisioningActivity"
$LOG_TAG  = 'DepEinrichtung'

$Root     = $PSScriptRoot
$AdbExe   = Join-Path $Root 'platform-tools\adb.exe'
$ApkDir   = Join-Path $Root 'apk'
$CfgFile  = Join-Path $Root 'mail-einstellungen.json'
$CsvFile  = Join-Path $Root 'mail-protokoll.csv'

function Write-Info([string]$t)  { Write-Host $t }
function Write-Ok([string]$t)    { Write-Host $t -ForegroundColor Green }
function Write-Warn2([string]$t) { Write-Host $t -ForegroundColor Yellow }
function Write-Err([string]$t)   { Write-Host $t -ForegroundColor Red }

function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '"', '\"') + '"'
}

# Setzt einen Wert für die Shell auf dem Gerät in einfache Anführungszeichen.
# So kommen Zeichen wie $ ( ) / unverändert an.
function Quote-DeviceShell([string]$a) {
    return "'" + ($a -replace "'", "'\''") + "'"
}

function Invoke-Adb([string[]]$ArgList, [int]$TimeoutSec = 120) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbExe
    $psi.Arguments = ($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ Code = -1; Out = "Zeitüberschreitung nach $TimeoutSec s" }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = ($outTask.Result + "`n" + $errTask.Result).Trim() }
}

function Load-MailSettings {
    if (-not (Test-Path $CfgFile)) {
        throw "mail-einstellungen.json fehlt. Bitte die Vorlage mail-einstellungen.beispiel.json kopieren und ausfüllen."
    }
    $cfg = Get-Content -Raw -Encoding UTF8 $CfgFile | ConvertFrom-Json
    foreach ($k in @('server', 'adressMuster', 'passwortRegel1')) {
        if (-not $cfg.$k) { throw "In mail-einstellungen.json fehlt der Eintrag '$k'." }
    }
    if ($cfg.passwortRegel1 -notmatch '\{NR\}') { throw "passwortRegel1 enthält kein {NR}." }
    return $cfg
}

# Liefert Adresse, Kontoname und die beiden möglichen Passwörter für eine Seriennummer.
function Get-MailAccount([string]$Nr, $Cfg) {
    $acc = [ordered]@{
        Nr        = $Nr
        Email     = $Cfg.adressMuster.Replace('{NR}', $Nr)
        Name      = $(if ($Cfg.kontoName) { $Cfg.kontoName.Replace('{NR}', $Nr) } else { '' })
        Server    = $Cfg.server
        Passwort1 = $Cfg.passwortRegel1.Replace('{NR}', $Nr)
        Passwort2 = $(if ($Cfg.passwortRegel2) { $Cfg.passwortRegel2.Replace('{NR}', $Nr) } else { '' })
    }
    return [pscustomobject]$acc
}

function Find-MailApk {
    $apk = Get-ChildItem -Path $ApkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw "Keine APK im Ordner $ApkDir gefunden." }
    return $apk.FullName
}

function Install-MailApp([string]$ApkPath) {
    Write-Info "App wird installiert: $(Split-Path $ApkPath -Leaf)"
    $r = Invoke-Adb @('install', '-r', '-g', $ApkPath) 300
    if ($r.Code -ne 0 -or $r.Out -notmatch 'Success') { throw "Installation fehlgeschlagen: $($r.Out)" }
}

# Startet die Einrichtung in der App und wartet auf das Ergebnis im Logcat.
# Rückgabe: Status (OK, OK_PASSWORT2, VORHANDEN, FEHLER_...) und Detailtext.
function Invoke-MailProvisioning($Acc, [int]$TimeoutSec = 90) {
    [void](Invoke-Adb @('logcat', '-c') 30)

    $cmd = "am start -W -a $ACTION -n $ACTIVITY" +
        " --es email " + (Quote-DeviceShell $Acc.Email) +
        " --es host " + (Quote-DeviceShell $Acc.Server) +
        " --es password " + (Quote-DeviceShell $Acc.Passwort1)
    if ($Acc.Passwort2) { $cmd += " --es password2 " + (Quote-DeviceShell $Acc.Passwort2) }
    if ($Acc.Name)      { $cmd += " --es name " + (Quote-DeviceShell $Acc.Name) }

    $r = Invoke-Adb @('shell', $cmd) 60
    if ($r.Out -match 'Error|Exception|Security') {
        return [pscustomobject]@{ Status = 'FEHLER'; Detail = "App konnte nicht gestartet werden: $($r.Out)" }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $log = Invoke-Adb @('logcat', '-d', '-s', "${LOG_TAG}:I") 30
        $m = [regex]::Match($log.Out, 'ERGEBNIS (\S+) ?(.*)')
        if ($m.Success) {
            return [pscustomobject]@{ Status = $m.Groups[1].Value; Detail = $m.Groups[2].Value.Trim() }
        }
    }
    return [pscustomobject]@{ Status = 'FEHLER'; Detail = "Kein Ergebnis nach $TimeoutSec s" }
}

# ---------------------------------------------------------------------------
# Postfach im cPanel anlegen (UAPI Email::add_pop mit API-Token)
# Rückgabe: ANGELEGT, VORHANDEN, UEBERSPRUNGEN (kein Token eingetragen) oder FEHLER
# ---------------------------------------------------------------------------
function Ensure-Mailbox($Acc, $Cfg) {
    if (-not ($Cfg.PSObject.Properties.Name -contains 'cpanelToken') -or -not $Cfg.cpanelToken -or
        $Cfg.cpanelToken -like 'HIER-*' -or -not $Cfg.cpanelBenutzer) {
        return [pscustomobject]@{ Status = 'UEBERSPRUNGEN'; Detail = 'Kein cPanel-Token in mail-einstellungen.json' }
    }
    $cpHost = $(if ($Cfg.PSObject.Properties.Name -contains 'cpanelServer' -and $Cfg.cpanelServer) { $Cfg.cpanelServer } else { 'dentaleyepad.net' })
    $quota  = $(if ($Cfg.PSObject.Properties.Name -contains 'postfachGroesseMB') { [int]$Cfg.postfachGroesseMB } else { 1024 })
    $parts  = $Acc.Email.Split('@')
    $url = 'https://{0}:2083/execute/Email/add_pop?email={1}&domain={2}&password={3}&quota={4}&send_welcome_email=0' -f `
        $cpHost, [Uri]::EscapeDataString($parts[0]), [Uri]::EscapeDataString($parts[1]),
        [Uri]::EscapeDataString($Acc.Passwort1), $quota
    $headers = @{ Authorization = ('cpanel {0}:{1}' -f $Cfg.cpanelBenutzer, $Cfg.cpanelToken) }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 60
    } catch {
        return [pscustomobject]@{ Status = 'FEHLER'; Detail = "cPanel nicht erreichbar oder Token falsch: $($_.Exception.Message)" }
    }
    $res = $(if ($r.PSObject.Properties.Name -contains 'result') { $r.result } else { $r })
    if ($res.status -eq 1) { return [pscustomobject]@{ Status = 'ANGELEGT'; Detail = $Acc.Email } }
    $err = (@($res.errors) -join ' ').Trim()
    if ($err -match 'exist') { return [pscustomobject]@{ Status = 'VORHANDEN'; Detail = $err } }
    return [pscustomobject]@{ Status = 'FEHLER'; Detail = "cPanel: $err" }
}

function Save-MailResult($Acc, $Res) {
    $row = [pscustomobject]@{
        Datum        = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Seriennummer = $Acc.Nr
        EMail        = $Acc.Email
        Ergebnis     = $Res.Status
        # Welche Passwort-Regel gepasst hat, ohne das Passwort selbst zu speichern
        Regel        = $(switch ($Res.Status) { 'OK' { '1' } 'OK_PASSWORT2' { '2' } default { '' } })
        Hinweis      = $Res.Detail
    }
    $exists = Test-Path $CsvFile
    $row | Export-Csv -Path $CsvFile -Append:$exists -NoTypeInformation -Delimiter ';' -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path $AdbExe)) { throw "adb.exe fehlt im Ordner $Root\platform-tools." }
    $cfg = Load-MailSettings

    while ($Seriennummer -notmatch '^\d{5}$') {
        $Seriennummer = (Read-Host 'Fünfstellige Seriennummer des Geräts').Trim()
    }
    $acc = Get-MailAccount $Seriennummer $cfg
    Write-Info "Postfach: $($acc.Email)"

    $dev = Invoke-Adb @('devices') 30
    $lines = @($dev.Out -split "`r?`n" | Where-Object { $_ -match '\tdevice$' })
    if ($lines.Count -ne 1) { throw "Es muss genau ein Gerät per USB verbunden und freigegeben sein (gefunden: $($lines.Count))." }

    $mb = Ensure-Mailbox $acc $cfg
    switch ($mb.Status) {
        'ANGELEGT'      { Write-Ok "Postfach im cPanel neu angelegt." }
        'VORHANDEN'     { Write-Info "Postfach gibt es schon im cPanel." }
        'UEBERSPRUNGEN' { Write-Warn2 "Postfach wird nicht automatisch angelegt (kein cPanel-Token eingetragen)." }
        default         { throw "Postfach konnte nicht angelegt werden. $($mb.Detail)" }
    }

    Install-MailApp (Find-MailApk)
    Write-Info 'Konto wird eingerichtet, Anmeldung am Mailserver wird geprüft ...'
    $res = Invoke-MailProvisioning $acc
    Save-MailResult $acc $res

    switch ($res.Status) {
        'OK'           { Write-Ok "Fertig. Konto $($acc.Email) ist eingerichtet." }
        'OK_PASSWORT2' { Write-Warn2 "Fertig. Konto $($acc.Email) ist eingerichtet, aber nur mit der ALTEN Passwort-Regel. Das Postfach sollte auf die gültige Regel umgestellt werden." }
        'VORHANDEN'    { Write-Ok "Konto $($acc.Email) war auf dem Gerät schon eingerichtet." }
        'FEHLER_ANMELDUNG' { Write-Err "Anmeldung abgelehnt. Gibt es das Postfach, und stimmen die Passwort-Regeln? ($($res.Detail))" }
        'FEHLER_NETZWERK'  { Write-Err "Mailserver nicht erreichbar. Hat das Gerät Internet (WLAN)? ($($res.Detail))" }
        default        { Write-Err "Einrichtung fehlgeschlagen: $($res.Status) $($res.Detail)" }
    }
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
