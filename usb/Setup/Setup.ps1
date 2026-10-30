#Requires -Version 5.1
<#
.SYNOPSIS
    Automatski pocetni setup novih Windows 11 Pro racunara.

.DESCRIPTION
    Pokrece se preko Start.bat. Radi u sekcijama:
      1. Temelj (uvek): admin prava, log, transcript, lock, state fajl, hvatanje gresaka
      2. Region  - vremenska zona, region, tastature
      3. Network - provera interneta, mrezni drajver sa flesa
      4. Apps    - Ninite sa flesa (ako ga ima); installeri iz Rucno\ se instaliraju rucno
      5. Browser - Chrome kao default browser (ako je instaliran)
      6. Drivers - Windows Update, drugi prolaz sa flesa
      7. Report  - izvestaj na desktopu

    Exit code: 0 = sve OK, 1 = bilo je gresaka u sekcijama, 2 = skripta nije pokrenuta.

.PARAMETER DryRun
    Proba: cita sistem i upisuje u log sta bi uradio. Nista ne menja, ne upisuje state fajl.

.PARAMETER Section
    Pokreni samo navedene sekcije. Za njih se state fajl ignorise (pokrecu se i ako su vec uradjene).

.EXAMPLE
    Start.bat -DryRun

.EXAMPLE
    Start.bat -Section Region,Apps
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Namerno: obojen ispis napretka na ekranu; Start-Transcript ga snima.')]
[CmdletBinding()]
param(
    [switch]$DryRun,

    # Imena moraju da se poklapaju sa kljucevima u $SectionMap (dole)
    [ValidateSet('Region', 'Network', 'Apps', 'Browser', 'Drivers', 'Report')]
    [string[]]$Section
)

# ============================================================================
#  PUTANJE I STANJE POKRETANJA
# ============================================================================

# Fiksne putanje (funkcije ih samo citaju)
$BaseDir        = Join-Path -Path $env:ProgramData -ChildPath 'Provisioning'
$LogDir         = Join-Path -Path $BaseDir -ChildPath 'Logs'
$RunStamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile        = Join-Path -Path $LogDir -ChildPath "Setup_$RunStamp.log"
$TranscriptFile = Join-Path -Path $LogDir -ChildPath "Transcript_$RunStamp.txt"
$StateFile      = Join-Path -Path $BaseDir -ChildPath 'state.json'
$LockFile       = Join-Path -Path $BaseDir -ChildPath 'setup.lock'

# Logovi na flesu: <fles>\Logs\<BIOS serijski>_<yyyy-MM-dd_HHmm>\ - Logs\ je u KORENU flesa (folder iznad Setup\).
# Serijski broj, ne ime racunara: ime je na svakoj masini pc1, serijski broj je jedinstven (i na nalepnici).
$UsbLogRoot     = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Logs'
$PantherSetupLog = Join-Path -Path $env:windir -ChildPath 'Panther\setupact.log'   # log instalacije Windowsa
$DiskCheckLog   = Join-Path -Path $UsbLogRoot -ChildPath 'Disk_check.txt'          # pise ga Check-Disk.cmd u WinPE-u
$PlaceholderSerials = @('', 'To Be Filled By O.E.M.', 'Default string', 'System Serial Number', 'O.E.M.', 'None',
    '0', 'Not Specified', 'Not Applicable', 'Chassis Serial Number', '0123456789')
try {
    $BiosSerial = "$((Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim()
}
catch {
    $BiosSerial = ''
}
# Placeholder (racunar od delova) -> ime racunara; znakovi koji ne smeju u ime foldera -> '-'
if ($PlaceholderSerials -contains $BiosSerial) {
    $BiosSerial = $env:COMPUTERNAME
}
$BiosSerial     = $BiosSerial -replace '[\\/:*?"<>|\s]', '-'
$UsbLogDir      = Join-Path -Path $UsbLogRoot -ChildPath ('{0}_{1}' -f $BiosSerial, (Get-Date -Format 'yyyy-MM-dd_HHmm'))

# Stanje ovog pokretanja (funkcije ga menjaju, zato $script:)
$script:RunStart       = Get-Date
$script:CurrentSection = 'Main'
$script:Errors         = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:Results        = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:State          = $null
$script:LockTaken      = $false
$script:TranscriptOn   = $false
$script:RebootRequired = $false   # "preporucen" restart (npr. Welcome screen) - samo poruka na kraju
$script:RebootReasons  = New-Object -TypeName 'System.Collections.Generic.List[string]'   # zasto je preporucen (log + izvestaj)
$script:RestartNeeded  = $false   # "potreban za nastavak" - sekcija ne moze dalje bez restarta (Request-Restart)
$script:RestartReasons = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:RestartPlanned = $false   # task je napravljen, restart ide posle Complete-Setup
$script:CleanupWarnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:CleanupDone    = $false
$script:CleanupCheck   = $null    # stvarno stanje posle ciscenja (Get-CleanupCheck) - za izvestaj
$script:GuardOriginal  = $null    # pocetne vrednosti zastite od restarta (za proveru posle vracanja)
$script:ReportFile     = $null    # izvestaj (sekcija 7) - kopira se i na fles
$script:ReportWarnings = New-Object -TypeName 'System.Collections.Generic.List[string]'   # !!! redovi - crveno na kraju
$script:DiagZip        = $null
$script:LogsKept       = $false   # logovi ostali u ProgramData (greske u sekcijama, kopija nepotpuna, brisanje palo)
$script:LogsWarning    = $false   # ... i to zasluzuje !!! (kopija nepotpuna ili brisanje palo - ne obicne greske)
$LogStatusMarker       = 'Logovi: (status se upisuje na kraju rada)'   # red u izvestaju koji Copy-ReportToUsb menja
$LogsShortcut          = Join-Path -Path ([Environment]::GetFolderPath('Desktop')) -ChildPath 'Provisioning LOGOVI.lnk'
$script:ExitCode       = 0
$script:InternetOk     = $false   # postavlja sekcija 3; koriste je sekcije kojima treba internet
$script:AdminPasswordResult = $null   # postavlja Set-AdminPasswordChange na kraju Setup-a; cita izvestaj

# ============================================================================
#  LOGOVANJE I GRESKE
# ============================================================================

function Write-Log {
    # Jedan red u log fajlu + isti red na ekranu (u boji po nivou)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DRYRUN')]
        [string]$Level = 'INFO',

        [string]$SectionName = $script:CurrentSection
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1,-6}] [{2,-8}] {3}' -f $timestamp, $Level, $SectionName, $Message

    $color = switch ($Level) {
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'DRYRUN' { 'Cyan' }
        default  { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    # Ako upis u fajl ne uspe, skripta ne sme da padne zbog loga
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "Upis u log nije uspeo: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Add-ErrorRecord {
    # Iz PowerShell greske izvlaci detalje (linija, komanda, poruka), upisuje ih u log
    # i pamti u $script:Errors (za dijagnostiku i izvestaj)
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$SectionName,

        # Ime koraka iz Invoke-Step (prazno ako greska nije u koraku)
        [string]$StepName = ''
    )

    $lineNumber = 0
    $command    = '(nepoznato)'
    if ($ErrorRecord.InvocationInfo) {
        $lineNumber = $ErrorRecord.InvocationInfo.ScriptLineNumber
        if ($ErrorRecord.InvocationInfo.Line) {
            $command = $ErrorRecord.InvocationInfo.Line.Trim()
        }
    }
    $message    = $ErrorRecord.Exception.Message -replace '\r?\n', ' '
    $scriptStack = $ErrorRecord.ScriptStackTrace -replace '\r?\n', ' <- '

    $script:Errors.Add([pscustomobject]@{
        Time       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Section    = $SectionName
        Step       = $StepName
        Line       = $lineNumber
        Command    = $command
        Message    = $message
        StackTrace = $scriptStack
    })

    if ($StepName) {
        Write-Log -Level ERROR -SectionName $SectionName -Message "Korak: $StepName"
    }
    Write-Log -Level ERROR -SectionName $SectionName -Message "Linija $lineNumber | Komanda: $command"
    Write-Log -Level ERROR -SectionName $SectionName -Message "Poruka: $message"
    Write-Log -Level ERROR -SectionName $SectionName -Message "Stack: $scriptStack"
}

# ============================================================================
#  IZMENE SISTEMA (DryRun) I KORACI
# ============================================================================

function Invoke-Change {
    # Svaka izmena sistema ide kroz ovu funkciju.
    # U DryRun-u samo upise sta bi uradio; inace izvrsi blok koda.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Log -Level DRYRUN -Message "Uradio bih: $Description"
        return
    }
    Write-Log -Message $Description
    & $Action
}

function Invoke-Step {
    # Jedan korak unutar sekcije, u svom try/catch. Greska se belezi (sekcija ce na kraju biti
    # Failed i ponavlja se sledeci put), ali sekcija nastavlja sa sledecim korakom.
    # Zato koraci moraju biti idempotentni: procitaj -> uporedi -> menjaj samo ako treba.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Log -Message "--- Korak: $Name"
    $ErrorActionPreference = 'Stop'
    try {
        & $Action
    }
    catch {
        Write-Log -Level ERROR -Message "Korak nije uspeo: $Name"
        Add-ErrorRecord -ErrorRecord $_ -SectionName $script:CurrentSection -StepName $Name
    }
}

function Assert-Setting {
    # Provera posle izmene: vrednost procitana iz sistema mora biti jednaka cilju, inace throw.
    # U DryRun-u nista nije menjano, pa nema sta da se proverava.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Expected
    )

    if ($DryRun) {
        return
    }
    if ($Actual -ne $Expected) {
        throw "$Name posle izmene je '$Actual', ocekivano '$Expected'"
    }
    Write-Log -Message "Provera OK: $Name = $Actual"
}

# ============================================================================
#  ADMIN PRAVA
# ============================================================================

function Get-TimeInfo {
    # Vremenska zona, trenutni pomak od UTC (sa letnjim vremenom), kultura i jezik UI - za log i dijagnostiku
    $offset = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date))
    $sign = '+'
    if ($offset -lt [System.TimeSpan]::Zero) {
        $sign = '-'
    }
    return '{0} (UTC{1}{2:hh\:mm}) | Kultura: {3} | Jezik UI: {4}' -f (Get-TimeZone).Id, $sign, $offset, (Get-Culture).Name, (Get-UICulture).Name
}

function Test-IsAdmin {
    # Da li trenutni proces ima PUN admin token (ne samo da je nalog u grupi Administrators)
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptArgument {
    # Parametri ovog pokretanja kao tekst - za admin kopiju (UAC) i za nastavak posle restarta (Resume.ps1)
    $parts = @()
    if ($DryRun) {
        $parts += '-DryRun'
    }
    if ($Section) {
        $parts += '-Section ' + ($Section -join ',')
    }
    return ($parts -join ' ')
}

function Invoke-Elevated {
    # Pokrece novu kopiju ove skripte kao administrator (UAC), sa ISTIM parametrima,
    # ceka da zavrsi i vraca njen exit code
    Write-Host 'Skripta nema admin prava - pokrecem novu kopiju kao administrator (UAC prozor)...' -ForegroundColor Yellow

    # Putanja ide u jednostruke navodnike; eventualni ' u putanji se udvostrucuje
    $scriptPath = $PSCommandPath -replace "'", "''"
    $command = "`$LASTEXITCODE = 2; & '$scriptPath' $(Get-ScriptArgument); exit `$LASTEXITCODE"

    $arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $command + '"'
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
        Write-Host "Admin kopija je zavrsila (exit code $($process.ExitCode)). Log: $LogDir" -ForegroundColor Yellow
        return $process.ExitCode
    }
    catch {
        # Najcesce: korisnik je kliknuo "No" u UAC prozoru
        Write-Host "Podizanje prava nije uspelo ili je odbijeno: $($_.Exception.Message)" -ForegroundColor Red
        return 2
    }
}

# ============================================================================
#  LOCK (zastita od duplog pokretanja)
# ============================================================================

function Lock-Setup {
    # Vraca $true ako je lock uzet, $false ako druga kopija vec radi
    if (Test-Path -Path $LockFile) {
        $oldPid     = Get-Content -Path $LockFile -TotalCount 1 -ErrorAction SilentlyContinue
        $oldProcess = $null
        if ($oldPid -match '^\d+$') {
            $oldProcess = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        }
        # Pravi vlasnik lock-a je krenuo PRE upisa lock fajla. Ako je proces mladji od fajla,
        # Windows je PID ponovo dodelio nekom drugom PowerShell-u - lock je mrtav.
        if ($oldProcess -and $oldProcess.ProcessName -like 'powershell*' -and
            $oldProcess.StartTime -le (Get-Item -Path $LockFile).LastWriteTime) {
            Write-Log -Level WARN -Message "Setup vec radi (PID $oldPid). Ova kopija se zavrsava."
            return $false
        }
        # Lock je ostao od prekinutog pokretanja (zatvoren prozor, nestanak struje)
        Write-Log -Level WARN -Message "Pronadjen stari lock (PID $oldPid vise ne radi) - brisem ga"
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }

    try {
        # New-Item bez -Force pada ako fajl vec postoji - stiti i kad dve kopije krenu istovremeno
        New-Item -ItemType File -Path $LockFile -Value $PID -ErrorAction Stop | Out-Null
        $script:LockTaken = $true
        Write-Log -Message "Lock uzet (PID $PID)"
        return $true
    }
    catch {
        Write-Log -Level WARN -Message "Lock nije uzet, druga kopija je upravo krenula: $($_.Exception.Message)"
        return $false
    }
}

function Unlock-Setup {
    # Brise lock samo ako ga je uzela OVA kopija
    if ($script:LockTaken) {
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
        $script:LockTaken = $false
    }
}

# ============================================================================
#  STATE FAJL (nastavak posle restarta)
# ============================================================================

function Get-SetupState {
    # Cita state fajl; ako ne postoji ili je ostecen - pravi novo, prazno stanje
    if (Test-Path -Path $StateFile) {
        try {
            $loaded = Get-Content -Path $StateFile -Raw -Encoding UTF8 -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            if ($loaded.FirstStart -and $loaded.Sections) {
                Write-Log -Message "State fajl ucitan (prvi start: $($loaded.FirstStart))"
                return $loaded
            }
            Write-Log -Level WARN -Message 'State fajl nema ocekivana polja - pravim novo stanje'
        }
        catch {
            Write-Log -Level WARN -Message "State fajl je ostecen ($($_.Exception.Message)) - pravim novo stanje"
        }
        # Ostecen fajl cuvamo za analizu
        Copy-Item -Path $StateFile -Destination (Join-Path -Path $BaseDir -ChildPath "state_ostecen_$RunStamp.json") -ErrorAction SilentlyContinue
    }
    else {
        Write-Log -Message 'State fajl ne postoji - prvo pokretanje'
    }

    return [pscustomobject]@{
        # 'o' = ISO format SA pomakom od UTC - ostaje tacan i posle promene vremenske zone (sekcija 2)
        FirstStart = $script:RunStart.ToString('o')
        Sections   = [pscustomobject]@{}
    }
}

function Save-SetupState {
    # Upisuje ceo state u JSON. U DryRun-u se nista ne upisuje.
    if ($DryRun) {
        return
    }
    try {
        $script:State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log -Level WARN -Message "Upis state fajla nije uspeo: $($_.Exception.Message)"
    }
}

function Get-SectionStatus {
    # Vraca status sekcije iz state fajla: Done, Failed, RebootPending, Running ili NotStarted
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $entry = $script:State.Sections.PSObject.Properties[$Name]
    if ($entry) {
        return $entry.Value.Status
    }
    return 'NotStarted'
}

function Get-SectionInterrupted {
    # Koliko puta je sekcija prekinuta usred rada (status je ostao Running)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $entry = $script:State.Sections.PSObject.Properties[$Name]
    if ($entry -and $entry.Value.PSObject.Properties['Interrupted']) {
        return [int]$entry.Value.Interrupted
    }
    return 0
}

function Save-SectionStatus {
    # Upisuje status jedne sekcije u state i odmah snima fajl
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string]$ErrorMessage = '',

        [int]$Interrupted = 0,

        [double]$Seconds = 0
    )
    if ($DryRun) {
        return
    }
    $entry = [pscustomobject]@{
        Status      = $Status
        Time        = (Get-Date).ToString('s')
        Error       = $ErrorMessage
        Interrupted = $Interrupted
        Seconds     = $Seconds
    }
    $script:State.Sections | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
    Save-SetupState
}

# ============================================================================
#  POKRETANJE SEKCIJE
# ============================================================================

function Invoke-Section {
    # Za jednu sekciju: pokreni ili preskoci, meri vreme, uhvati gresku, upisi state.
    # Greska u sekciji se belezi i skripta ide na sledecu sekciju.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $script:CurrentSection = $Name
    $requested = $Section -contains $Name

    # 1. Odluka: pokrenuti ili preskociti
    $skipReason = $null
    if ($Section -and -not $requested) {
        $skipReason = 'nije navedena u -Section'
    }
    elseif (-not $requested -and $Name -ne 'Report' -and (Get-SectionStatus -Name $Name) -eq 'Done') {
        # Izvestaj se pravi uvek iznova - mora da pokaze stanje POSLE poslednjeg pokretanja
        $skipReason = 'vec uradjeno (state fajl)'
    }
    if ($skipReason) {
        Write-Log -Message "Preskacem: $skipReason"
        $script:Results.Add([pscustomobject]@{ Section = $Name; Status = 'Skipped'; Seconds = 0 })
        $script:CurrentSection = 'Main'
        return
    }

    # 2. Prekid u prethodnom pokretanju: status je ostao Running (nestanak struje, zatvoren prozor, restart).
    # Koraci su idempotentni, pa sekciju pokrecemo ponovo - ali posle $MaxInterrupted prekida ne, da se ne vrti u krug.
    $interrupted = 0
    if ((Get-SectionStatus -Name $Name) -eq 'Running') {
        $interrupted = (Get-SectionInterrupted -Name $Name) + 1
        Write-Log -Level WARN -Message "Sekcija je prekinuta u prethodnom pokretanju ($interrupted. put) - pokrecem je ponovo"
        if ($interrupted -ge $MaxInterrupted) {
            try {
                throw "Sekcija je prekinuta $interrupted puta zaredom - ne pokrecem je ponovo (proveri log prethodnih pokretanja)"
            }
            catch {
                Add-ErrorRecord -ErrorRecord $_ -SectionName $Name
            }
            Save-SectionStatus -Name $Name -Status 'Failed' -ErrorMessage $script:Errors[$script:Errors.Count - 1].Message
            $script:Results.Add([pscustomobject]@{ Section = $Name; Status = 'Failed'; Seconds = 0 })
            $script:CurrentSection = 'Main'
            return
        }
    }

    # 3. Pokretanje - Running se upisuje odmah, da sledece pokretanje vidi ako je ovo prekinuto
    Write-Log -Message 'START'
    Save-SectionStatus -Name $Name -Status 'Running' -Interrupted $interrupted
    $timer  = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'Done'

    # Svaka greska (i non-terminating) postaje terminating, pa je catch vidi.
    # Vazi samo unutar ove funkcije i onoga sto ona pozove.
    $errorsBefore = $script:Errors.Count
    $ErrorActionPreference = 'Stop'
    try {
        & $Action
    }
    catch {
        Add-ErrorRecord -ErrorRecord $_ -SectionName $Name
    }
    $timer.Stop()

    # Failed ako je zabelezena bilo koja greska - iz catch-a iznad ili iz nekog Invoke-Step koraka.
    # RebootPending: sekcija trazi restart pre nastavka - posle restarta se pokrece ponovo (nije Done).
    if ($script:Errors.Count -gt $errorsBefore) {
        $status = 'Failed'
    }
    elseif ($script:RestartNeeded) {
        $status = 'RebootPending'
    }

    # 4. Kraj: log, state, rezime
    $seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
    $lastError = ''
    # U rezimeu DryRun uspeh pise "DryRun", da se ne pomesa sa stvarno uradjenim
    $resultStatus = $status
    if ($status -eq 'Done') {
        if ($DryRun) {
            $resultStatus = 'DryRun'
        }
        Write-Log -Message "KRAJ - USPEH ($seconds s)"
    }
    elseif ($status -eq 'RebootPending') {
        Write-Log -Level WARN -Message "KRAJ - CEKA RESTART ($seconds s)"
    }
    else {
        Write-Log -Level ERROR -Message "KRAJ - GRESKA ($seconds s)"
        $lastError = $script:Errors[$script:Errors.Count - 1].Message
    }
    Save-SectionStatus -Name $Name -Status $status -ErrorMessage $lastError -Seconds $seconds
    $script:Results.Add([pscustomobject]@{ Section = $Name; Status = $resultStatus; Seconds = $seconds })
    $script:CurrentSection = 'Main'
}

# ============================================================================
#  RESTART I NASTAVAK (planiran restart -> task "At logon" -> nastavak)
# ============================================================================

# Dogovor 2026-10-23: task samo za PLANIRAN restart, bez AutoAdminLogon (tehnicar se sam uloguje),
# najvise $MaxRestarts restarta. Na kraju na masini ne sme ostati nista sto radi sa admin pravima.
$ResumeTaskName = 'Provisioning-Resume'
$ResumeScript   = Join-Path -Path $BaseDir -ChildPath 'Resume.ps1'
$MaxRestarts    = 3
$MaxInterrupted = 3      # posle toliko prekida iste sekcije zaredom - Failed, bez ponovnog pokretanja
$RestartDelaySec = 60    # vreme do restarta - za otkazivanje: shutdown /a

# Zastita od restarta koji bi Windows Update uradio sam usred rada: politika + active hours.
# Pocetne vrednosti se cuvaju u state.json (samo prvi put) i vracaju na kraju SVAKOG pokretanja.
$AuPolicyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$UxSettingsKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$GuardValues = @(
    @{ Path = $AuPolicyKey;   Reg = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoRebootWithLoggedOnUsers' }
    @{ Path = $UxSettingsKey; Reg = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';         Name = 'ActiveHoursStart' }
    @{ Path = $UxSettingsKey; Reg = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';         Name = 'ActiveHoursEnd' }
    @{ Path = $UxSettingsKey; Reg = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';         Name = 'SmartActiveHoursState' }
)

function Get-StateValue {
    # Vrednost iz state-a ($null ako je nema)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $property = $script:State.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Save-StateValue {
    # Upisuje vrednost u state i snima fajl ($null = brisanje vrednosti)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )
    if ($null -eq $Value) {
        $script:State.PSObject.Properties.Remove($Name)
    }
    else {
        $script:State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    Save-SetupState
}

function Add-RebootRecommendation {
    # "Preporucen" restart: ne zaustavlja Setup, samo poruka na kraju i u izvestaju - sa razlogom (koji korak/kljuc)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )
    $script:RebootRequired = $true
    if (-not $script:RebootReasons.Contains($Reason)) {
        $script:RebootReasons.Add($Reason)
    }
    Write-Log -Level WARN -Message "Preporucen restart: $Reason"
}

function Request-Restart {
    # Sekcija javlja da ne moze dalje bez restarta (WU RebootRequired, 3010 od pnputil/msiexec, alat proizvodjaca).
    # Sekcija ce biti RebootPending, ostale sekcije cekaju, restart ide na kraju pokretanja.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )
    $script:RestartNeeded = $true
    $script:RestartReasons.Add($Reason)
    Write-Log -Level WARN -Message "Potreban restart pre nastavka: $Reason"
}

function Get-PendingRebootSource {
    # Da li Windows vec ceka restart od ranije (pre nego sto smo bilo sta instalirali)
    $sources = @()
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $sources += 'Windows Update'
    }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $sources += 'Component Based Servicing'
    }
    $renames = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($renames) {
        $sources += 'PendingFileRenameOperations'
    }
    return $sources
}

function Get-RegistryValueOrNull {
    # Vrednost iz registry-ja ili $null ako ne postoji
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($item) {
        return $item.$Name
    }
    return $null
}

function Format-GuardValue {
    # Trenutne vrednosti zastite, jedan red za log
    $parts = foreach ($value in $GuardValues) {
        $current = Get-RegistryValueOrNull -Path $value.Path -Name $value.Name
        if ($null -eq $current) {
            $current = '(nema)'
        }
        "$($value.Name)=$current"
    }
    return ($parts -join ', ')
}

function Enable-RestartGuard {
    # Dok Setup radi, Windows Update ne sme sam da restartuje: NoAutoRebootWithLoggedOnUsers=1 +
    # active hours od sada do +18 h (maksimum koji Windows dozvoljava) + rucni (ne "pametni") active hours.
    Write-Log -Message "Zastita od automatskog restarta - trenutno: $(Format-GuardValue)"
    if ($DryRun) {
        Write-Log -Level DRYRUN -Message 'Uradio bih: NoAutoRebootWithLoggedOnUsers=1, active hours sada..+18 h (na kraju vracam)'
        return
    }
    # Pocetne vrednosti samo PRVI put - posle pada skripte bi inace nase vrednosti zapamtili kao pocetne
    if (-not (Get-StateValue -Name 'Original')) {
        $values = [ordered]@{}
        foreach ($value in $GuardValues) {
            $values[$value.Name] = Get-RegistryValueOrNull -Path $value.Path -Name $value.Name
        }
        Save-StateValue -Name 'Original' -Value ([pscustomobject]@{
                AuKeyExisted = (Test-Path -Path $AuPolicyKey)
                WuKeyExisted = (Test-Path -Path (Split-Path -Path $AuPolicyKey -Parent))
                UxKeyExisted = (Test-Path -Path $UxSettingsKey)
                Values       = [pscustomobject]$values
            })
        Write-Log -Message 'Pocetne vrednosti sacuvane u state.json'
    }
    # New-Item samo ako kljuc ne postoji: New-Item -Force na POSTOJECEM kljucu brise njegove vrednosti
    foreach ($key in @($AuPolicyKey, $UxSettingsKey)) {
        if (-not (Test-Path -Path $key)) {
            New-Item -Path $key -Force | Out-Null
        }
    }
    $start = (Get-Date).Hour
    $end   = ($start + 18) % 24
    Set-ItemProperty -Path $AuPolicyKey -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
    Set-ItemProperty -Path $UxSettingsKey -Name 'SmartActiveHoursState' -Value 0 -Type DWord
    Set-ItemProperty -Path $UxSettingsKey -Name 'ActiveHoursStart' -Value $start -Type DWord
    Set-ItemProperty -Path $UxSettingsKey -Name 'ActiveHoursEnd' -Value $end -Type DWord
    Write-Log -Message "Zastita ukljucena: $(Format-GuardValue)"
}

function Get-GuardRestoreCommand {
    # Tacna komanda za rucno vracanje jedne vrednosti (za WARN u izvestaju)
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Value,

        [AllowNull()]
        [object]$Original
    )
    if ($null -eq $Original) {
        return "reg delete `"$($Value.Reg)`" /v $($Value.Name) /f"
    }
    return "reg add `"$($Value.Reg)`" /v $($Value.Name) /t REG_DWORD /d $Original /f"
}

function Restore-RestartGuard {
    # Vraca pocetne vrednosti iz state.json. Da li je vraceno proverava Get-CleanupCheck (zato ih pamtimo i ovde).
    $original = Get-StateValue -Name 'Original'
    if (-not $original) {
        return
    }
    $script:GuardOriginal = $original
    $failed = 0
    foreach ($value in $GuardValues) {
        $wanted = $original.Values.PSObject.Properties[$value.Name].Value
        try {
            if ($null -eq $wanted) {
                if ($null -ne (Get-RegistryValueOrNull -Path $value.Path -Name $value.Name)) {
                    Remove-ItemProperty -LiteralPath $value.Path -Name $value.Name -ErrorAction Stop
                }
            }
            else {
                Set-ItemProperty -LiteralPath $value.Path -Name $value.Name -Value $wanted -Type DWord -ErrorAction Stop
            }
        }
        catch {
            Write-Log -Level WARN -Message "Vracanje $($value.Name) nije uspelo: $($_.Exception.Message)"
        }
        # Ako nije vraceno, pocetne vrednosti ostaju u state.json (sledece pokretanje pokusava ponovo)
        $now = Get-RegistryValueOrNull -Path $value.Path -Name $value.Name
        if ("$now" -ne "$wanted") {
            $failed++
        }
    }
    # Kljucevi koje smo mi napravili - brisu se samo ako su prazni
    $keys = @(
        @{ Path = $AuPolicyKey; Existed = $original.AuKeyExisted }
        @{ Path = (Split-Path -Path $AuPolicyKey -Parent); Existed = $original.WuKeyExisted }
        @{ Path = $UxSettingsKey; Existed = $original.UxKeyExisted }
    )
    foreach ($key in $keys) {
        if (-not $key.Existed -and (Test-Path -Path $key.Path)) {
            $item = Get-Item -Path $key.Path
            if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
                Remove-Item -Path $key.Path -ErrorAction SilentlyContinue
            }
        }
    }
    if ($failed -eq 0) {
        Write-Log -Message "Zastita od automatskog restarta vracena na pocetno: $(Format-GuardValue)"
        Save-StateValue -Name 'Original' -Value $null
    }
}

function Register-ResumeTask {
    # Task "At logon" za nalog koji pokrece skriptu, sa najvisim pravima (bez UAC prozora), vidljiv prozor.
    # Pokrece Resume.ps1, koji nadje fles (slovo moze biti drugo), proveri SHA256 Setup.ps1 i pokrene Start.bat.
    $hash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $template = @'
# Provisioning - nastavak posle planiranog restarta.
# Pravi ga Setup.ps1; Setup.ps1 ga brise (zajedno sa taskom) na pocetku sledeceg pokretanja.
$expectedHash = '__HASH__'
$arguments    = '__ARGS__'
$logFile      = Join-Path -Path '__LOGDIR__' -ChildPath ('Resume_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

function Write-ResumeLog {
    param([string]$Message)
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Fles posle logovanja ponekad jos nije spreman - do 6 x 10 s
$found = $null
for ($i = 1; $i -le 6 -and -not $found; $i++) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) {
            continue
        }
        $candidate = Join-Path -Path $drive.RootDirectory.FullName -ChildPath 'Setup\Setup.ps1'
        if (Test-Path -LiteralPath $candidate) {
            if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $expectedHash) {
                $found = $candidate
                break
            }
            Write-ResumeLog "Preskacem $candidate - SHA256 nije isti kao pri zakazivanju restarta"
        }
    }
    if (-not $found -and $i -lt 6) {
        Start-Sleep -Seconds 10
    }
}
if (-not $found) {
    Write-ResumeLog 'Fles sa istim Setup.ps1 nije nadjen.'
    Write-Host 'Ubaci fles i pokreni <fles>\Setup\Start.bat kao administrator - Setup nastavlja gde je stao.' -ForegroundColor Red
    cmd.exe /c pause
    exit 1
}
$bat = Join-Path -Path (Split-Path -Path $found -Parent) -ChildPath 'Start.bat'
Write-ResumeLog "Nastavljam: $bat $arguments"
Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""' + $bat + '" ' + $arguments + '"')
exit 0
'@
    $content = $template.Replace('__HASH__', $hash).Replace('__ARGS__', (Get-ScriptArgument)).Replace('__LOGDIR__', $LogDir)
    # ASCII - isto pravilo kao za Setup.ps1 (PS 5.1 fajl bez BOM-a cita kao ANSI)
    Set-Content -LiteralPath $ResumeScript -Value $content -Encoding ASCII

    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ResumeScript`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT30S'   # mreza i fles posle logovanja
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Provisioning: nastavak Setup.ps1 posle planiranog restarta (brise se sam)' -Force | Out-Null
    if (-not (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue)) {
        throw "Task $ResumeTaskName nije napravljen"
    }
    Write-Log -Message "Task $ResumeTaskName napravljen (At logon: $user, +30 s, najvisa prava) -> $ResumeScript"
}

function Unregister-ResumeTask {
    # Brise task i Resume.ps1. Poziva se na pocetku svakog pokretanja (i nastavka) i proverava na kraju.
    if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log -Message "Task $ResumeTaskName obrisan"
    }
    if (Test-Path -LiteralPath $ResumeScript) {
        Remove-Item -LiteralPath $ResumeScript -Force -ErrorAction SilentlyContinue
        Write-Log -Message "$ResumeScript obrisan"
    }
}

function Invoke-RestartPlan {
    # Posle sekcija: ako je neka trazila restart - broj restarta, task, pa restart posle Complete-Setup
    $count = [int](Get-StateValue -Name 'RebootCount') + 1
    Write-Log -Level WARN -Message "Restart potreban ($($script:RestartReasons -join '; '))"
    if ($count -gt $MaxRestarts) {
        try {
            throw "Potrebno je vise od $MaxRestarts restarta - nastavak tek posle rucne provere (poslednji razlog: $($script:RestartReasons[$script:RestartReasons.Count - 1]))"
        }
        catch {
            Add-ErrorRecord -ErrorRecord $_ -SectionName 'Main'
        }
        # Sekcije koje cekaju restart postaju Failed sa istom porukom (ide u izvestaj)
        foreach ($property in @($script:State.Sections.PSObject.Properties)) {
            if ($property.Value.Status -eq 'RebootPending') {
                Save-SectionStatus -Name $property.Name -Status 'Failed' -ErrorMessage $script:Errors[$script:Errors.Count - 1].Message
            }
        }
        return
    }
    if ($DryRun) {
        Write-Log -Level DRYRUN -Message "Uradio bih: restart $count/$MaxRestarts, task $ResumeTaskName za nastavak"
        return
    }
    Save-StateValue -Name 'RebootCount' -Value $count
    # Ukupno za izvestaj - RebootCount se nulira kad pokretanje prodje bez restarta, ovaj ne
    Save-StateValue -Name 'RestartsTotal' -Value ([int](Get-StateValue -Name 'RestartsTotal') + 1)
    Register-ResumeTask
    $script:RestartPlanned = $true
    Write-Log -Level WARN -Message "Restart $count/$MaxRestarts zakazan: za $RestartDelaySec s posle kopiranja logova (otkazivanje: shutdown /a)"
}

# AutoLogon iz autounattend.xml (1 logovanje): posle prvog logovanja lozinka ne sme ostati na masini.
$WinlogonKey        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$WinlogonReg        = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PantherAnswerFiles = @(
    (Join-Path -Path $env:windir -ChildPath 'Panther\unattend.xml')
    (Join-Path -Path $env:windir -ChildPath 'Panther\autounattend.xml')
    (Join-Path -Path $env:windir -ChildPath 'Panther\Unattend\unattend.xml')
)

function Clear-AutoLogon {
    # Na pocetku svakog pokretanja: brise lozinku za automatsko logovanje i kes odgovora (Panther\unattend.xml).
    # AutoLogon je vec iskoriscen (ovo pokretanje je posle logovanja), a planiran restart ionako ceka rucno logovanje.
    $password = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'DefaultPassword'
    $auto     = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'AutoAdminLogon'
    $count    = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'AutoLogonCount'
    $answers  = @($PantherAnswerFiles | Where-Object { Test-Path -LiteralPath $_ })
    if ($null -eq $password -and "$auto" -ne '1' -and $null -eq $count -and $answers.Count -eq 0) {
        Write-Log -Message 'AutoLogon: nije ukljucen, nema lozinke ni kesa odgovora'
        return
    }
    # Vrednost lozinke se NIKAD ne upisuje u log - samo da li postoji. Kes odgovora: samo putanja (sadrzaj moze imati lozinku)
    Write-Log -Message "AutoLogon: AutoAdminLogon=$auto | DefaultPassword postoji: $($null -ne $password) | AutoLogonCount=$count | kes odgovora: $($answers.Count)"
    foreach ($file in $answers) {
        Write-Log -Message "  Kes odgovora postoji: $file (ne kopira se - moze sadrzati lozinku)"
    }
    if ($DryRun) {
        Write-Log -Level DRYRUN -Message "Uradio bih: brisanje DefaultPassword i AutoLogonCount, AutoAdminLogon=0, brisanje kesa odgovora: $($answers -join ', ')"
        return
    }
    if ($null -ne $password) {
        Remove-ItemProperty -LiteralPath $WinlogonKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    }
    if ($null -ne $count) {
        Remove-ItemProperty -LiteralPath $WinlogonKey -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    }
    if ("$auto" -eq '1') {
        Set-ItemProperty -LiteralPath $WinlogonKey -Name 'AutoAdminLogon' -Value '0' -ErrorAction SilentlyContinue
    }
    foreach ($file in $answers) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    Write-Log -Message 'AutoLogon: lozinka i kes odgovora obrisani, AutoAdminLogon=0'
}

# Nalog iz autounattend.xml ima JAVNU podrazumevanu lozinku "admin" - Windows mora da trazi novu pri sledecem logovanju.
$AdminAccountName = 'admin'

function Get-AdminPasswordState {
    # Stanje naloga iz WinNT provajdera (ADSI): UserFlags bit 0x10000 = "Password never expires",
    # PasswordExpired 1 = Windows trazi novu lozinku pri sledecem logovanju. $null = nalog ne postoji.
    # ChangedAfterInstall: PasswordLastSet je vise od 10 min posle nastanka profila naloga (prvo logovanje = AutoLogon
    # odmah posle OOBE-a, gde je lozinka postavljena) = tehnicar je vec promenio lozinku.
    # Ne InstallDate: upisuje se PRE OOBE-a (lozinka bi uvek bila "posle instalacije") i menja ga feature update.
    $user = Get-LocalUser -Name $AdminAccountName -ErrorAction SilentlyContinue
    if (-not $user) {
        return $null
    }
    $adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminAccountName,user"
    $profileCreated = $null
    $userProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID = '$($user.SID.Value)'" -ErrorAction SilentlyContinue
    if ($userProfile -and $userProfile.LocalPath -and (Test-Path -LiteralPath $userProfile.LocalPath)) {
        $profileCreated = (Get-Item -LiteralPath $userProfile.LocalPath -Force).CreationTime
    }
    $changed = [bool]($user.PasswordLastSet -and $profileCreated -and $user.PasswordLastSet -gt $profileCreated.AddMinutes(10))
    return [pscustomobject]@{
        NeverExpires        = (([int]$adsi.UserFlags.Value -band 0x10000) -ne 0)
        MustChange          = ([int]$adsi.PasswordExpired.Value -eq 1)
        MayChange           = [bool]$user.UserMayChangePassword
        PasswordLastSet     = $user.PasswordLastSet
        ProfileCreated      = $profileCreated
        ChangedAfterInstall = $changed
    }
}

function Set-AdminPasswordChange {
    # Na kraju celog Setup-a: "nova lozinka pri sledecem logovanju" za nalog admin.
    # net user /logonpasswordchg:yes ne radi dok je ukljuceno "Password never expires" (ni kad korisnik ne sme
    # da menja lozinku) - zato se to prvo iskljucuje. Trenutna sesija se ne prekida; trazi se pri sledecem logovanju.
    $before = Get-AdminPasswordState
    if (-not $before) {
        $script:AdminPasswordResult = "nalog $AdminAccountName ne postoji - nista nije podeseno"
        Write-Log -Level WARN -Message "Lozinka: $($script:AdminPasswordResult)"
        return
    }
    Write-Log -Message "Nalog ${AdminAccountName}: PasswordNeverExpires=$($before.NeverExpires) | UserMayChangePassword=$($before.MayChange) | nova lozinka pri sledecem logovanju=$($before.MustChange) | PasswordLastSet=$($before.PasswordLastSet) | profil napravljen=$($before.ProfileCreated)"
    if ($before.MustChange) {
        Write-Log -Message "Nalog ${AdminAccountName}: nova lozinka pri sledecem logovanju je vec podesena"
        $script:AdminPasswordResult = 'OK'
        return
    }
    if ($before.ChangedAfterInstall) {
        # Ponovno pokretanje posle predaje/promene lozinke - ne trazimo novu jos jednom
        $script:AdminPasswordResult = "lozinka je vec promenjena posle instalacije (PasswordLastSet $($before.PasswordLastSet), profil $($before.ProfileCreated)) - nova se ne trazi"
        Write-Log -Message "Nalog ${AdminAccountName}: $($script:AdminPasswordResult)"
        return
    }
    if ($before.NeverExpires) {
        Invoke-Change -Description "Nalog ${AdminAccountName}: iskljucujem PasswordNeverExpires" -Action {
            Set-LocalUser -Name $AdminAccountName -PasswordNeverExpires $false -ErrorAction Stop
        }
    }
    if (-not $before.MayChange) {
        Invoke-Change -Description "Nalog ${AdminAccountName}: ukljucujem UserMayChangePassword" -Action {
            Set-LocalUser -Name $AdminAccountName -UserMayChangePassword $true -ErrorAction Stop
        }
    }
    Invoke-Change -Description "net user $AdminAccountName /logonpasswordchg:yes (nova lozinka pri sledecem logovanju)" -Action {
        # Spoljna komanda ne baca PowerShell gresku - exit code proveravamo sami.
        # Bez 2>&1: u PS 5.1 bi svaki red na stderr postao greska i prekinuo korak (stderr ide u transcript)
        $output = & net.exe user $AdminAccountName /logonpasswordchg:yes
        $exitCode = $LASTEXITCODE
        Write-Log -Message "net user: exit code $exitCode | $(($output | Out-String).Trim())"
        if ($exitCode -ne 0) {
            throw "net user $AdminAccountName /logonpasswordchg:yes vratio exit code $exitCode"
        }
    }
    if ($DryRun) {
        $script:AdminPasswordResult = 'DryRun - nije podeseno'
        return
    }
    # Provera stvarnog stanja posle izmene (ne da li su komande prosle)
    $after = Get-AdminPasswordState
    Assert-Setting -Name "Nalog $AdminAccountName PasswordNeverExpires" -Actual "$($after.NeverExpires)" -Expected 'False'
    Assert-Setting -Name "Nalog $AdminAccountName nova lozinka pri sledecem logovanju" -Actual "$($after.MustChange)" -Expected 'True'
    $script:AdminPasswordResult = 'OK'
}

function Add-CleanupCheck {
    # Jedna stavka provere ciscenja u listu: sta, da li je OK, sta je zateceno, rucna komanda ako nije OK.
    # AllowEmptyCollection: lista je PRAZNA pri prvom pozivu (tek se puni) - Mandatory bez ovoga odbija praznu
    # kolekciju ("Cannot bind argument ... empty collection"), test B.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [Parameter(Mandatory = $true)]
        [string]$Item,

        [Parameter(Mandatory = $true)]
        [bool]$Ok,

        [Parameter(Mandatory = $true)]
        [string]$Now,

        [Parameter(Mandatory = $true)]
        [string]$Fix
    )
    $List.Add([pscustomobject]@{ Item = $Item; Ok = $Ok; Now = $Now; Fix = $Fix })
}

function Get-CleanupCheck {
    # Stvarno stanje POSLE ciscenja, procitano iz sistema - odlucuje sta je zateceno, ne da li su komande prosle.
    # Task i Resume.ps1 se ne proveravaju kad je restart planiran: tada namerno ostaju do nastavka.
    $checks = New-Object -TypeName 'System.Collections.Generic.List[object]'

    if (-not $script:RestartPlanned -and -not $script:RestartNeeded) {
        $task = [bool](Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue)
        Add-CleanupCheck -List $checks -Item "Task $ResumeTaskName" -Ok (-not $task) -Now $(if ($task) { 'postoji' } else { 'nema' }) `
            -Fix "schtasks /Delete /TN $ResumeTaskName /F"
        $resume = Test-Path -LiteralPath $ResumeScript
        Add-CleanupCheck -List $checks -Item $ResumeScript -Ok (-not $resume) -Now $(if ($resume) { 'postoji' } else { 'nema' }) `
            -Fix "del `"$ResumeScript`""
    }

    # AutoLogon: vrednost lozinke se NIKAD ne ispisuje - samo da li postoji
    $auto = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'AutoAdminLogon'
    Add-CleanupCheck -List $checks -Item 'AutoAdminLogon' -Ok ("$auto" -ne '1') -Now $(if ($null -eq $auto) { '(nema)' } else { "'$auto'" }) `
        -Fix "reg add `"$WinlogonReg`" /v AutoAdminLogon /t REG_SZ /d 0 /f"
    $password = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'DefaultPassword'
    Add-CleanupCheck -List $checks -Item 'DefaultPassword' -Ok ($null -eq $password) -Now $(if ($null -eq $password) { '(nema)' } else { 'postoji' }) `
        -Fix "reg delete `"$WinlogonReg`" /v DefaultPassword /f"
    $count = Get-RegistryValueOrNull -Path $WinlogonKey -Name 'AutoLogonCount'
    Add-CleanupCheck -List $checks -Item 'AutoLogonCount' -Ok ($null -eq $count) -Now $(if ($null -eq $count) { '(nema)' } else { "$count" }) `
        -Fix "reg delete `"$WinlogonReg`" /v AutoLogonCount /f"
    foreach ($file in $PantherAnswerFiles) {
        $exists = Test-Path -LiteralPath $file
        Add-CleanupCheck -List $checks -Item $file -Ok (-not $exists) -Now $(if ($exists) { 'postoji' } else { 'nema' }) `
            -Fix "del `"$file`""
    }

    # Zastita od restarta: uporedjuje se sa pocetnim vrednostima (Restore-RestartGuard ih je zapamtio)
    if ($script:GuardOriginal) {
        foreach ($value in $GuardValues) {
            $wanted = $script:GuardOriginal.Values.PSObject.Properties[$value.Name].Value
            $now    = Get-RegistryValueOrNull -Path $value.Path -Name $value.Name
            Add-CleanupCheck -List $checks -Item $value.Name -Ok ("$now" -eq "$wanted") -Now "sada '$now', pocetno '$wanted'" `
                -Fix (Get-GuardRestoreCommand -Value $value -Original $wanted)
        }
    }
    else {
        Add-CleanupCheck -List $checks -Item 'Zastita od restarta (politika, active hours)' -Ok $false `
            -Now "pocetne vrednosti nisu zapamcene - sada: $(Format-GuardValue)" `
            -Fix 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" i reg query "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" - uporedi sa stanjem pre Setup-a'
    }
    return $checks
}

function Invoke-FinalCleanup {
    # Na kraju pokretanja: vracanje zastite od restarta; bez planiranog restarta i brisanje taska i Resume.ps1.
    # Posle toga PROVERA stvarnog stanja (Get-CleanupCheck) - sta ostane = WARN sa tacnom komandom.
    # Poziva se PRE izvestaja (da izvestaj vidi rezultat) i iz Complete-Setup (ako nije bilo).
    # Samo ako je OVA kopija radila (lock) - inace bi pokvarili kopiju koja jos radi. DryRun nista nije menjao.
    if ($script:CleanupDone -or -not $script:LockTaken -or -not $script:State -or $DryRun) {
        return
    }
    $script:CleanupDone = $true
    try {
        Restore-RestartGuard
        if (-not $script:RestartPlanned -and -not $script:RestartNeeded) {
            Unregister-ResumeTask
        }
    }
    catch {
        $script:CleanupWarnings.Add("Ciscenje nije zavrseno: $($_.Exception.Message)")
    }
    try {
        $script:CleanupCheck = @(Get-CleanupCheck)
        foreach ($check in $script:CleanupCheck) {
            if ($check.Ok) {
                Write-Log -Message "Ciscenje provereno: OK  $($check.Item) ($($check.Now))"
            }
            else {
                $script:CleanupWarnings.Add("$($check.Item) - $($check.Now). Rucno: $($check.Fix)")
            }
        }
    }
    catch {
        $script:CleanupWarnings.Add("Provera ciscenja nije uradjena: $($_.Exception.Message)")
    }
    foreach ($warning in $script:CleanupWarnings) {
        Write-Log -Level WARN -Message "CISCENJE: $warning"
    }
}

function Invoke-PlannedRestart {
    # Posle Complete-Setup (log je vec zatvoren i kopiran) - zato samo ekran, bez Write-Log
    Write-Host ''
    Write-Host "!!! RESTART ZA $RestartDelaySec s - posle logovanja Setup nastavlja sam (task $ResumeTaskName)." -ForegroundColor Red
    Write-Host '!!! Otkazivanje restarta: shutdown /a  (task ostaje - nastavak pri sledecem logovanju ili rucno Start.bat)' -ForegroundColor Red
    & shutdown.exe /r /t $RestartDelaySec /c "Provisioning: restart za nastavak Setup-a. Otkazivanje: shutdown /a"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "shutdown nije uspeo (exit code $LASTEXITCODE) - restartuj rucno; Setup nastavlja posle logovanja." -ForegroundColor Red
    }
}

# ============================================================================
#  ZAVRSETAK: DIJAGNOSTIKA, KOPIJA NA FLES
# ============================================================================

function Export-DiagnosticPackage {
    # Samo ako je bilo gresaka: nasi logovi + Event Viewer + podaci o sistemu, sve u .zip
    $diagDir = Join-Path -Path $BaseDir -ChildPath "Diagnostics_$RunStamp"
    Write-Log -Message "Bilo je gresaka ($($script:Errors.Count)) - pravim dijagnosticki paket"
    New-Item -ItemType Directory -Path $diagDir -Force -ErrorAction Stop | Out-Null

    # 1. Nasi fajlovi + spisak gresaka
    foreach ($file in @($LogFile, $TranscriptFile, $StateFile)) {
        if (Test-Path -Path $file) {
            Copy-Item -Path $file -Destination $diagDir -Force
        }
    }
    $script:Errors | Export-Csv -Path (Join-Path -Path $diagDir -ChildPath 'Errors.csv') -NoTypeInformation -Encoding UTF8

    # 2. Event Viewer: Critical (1), Error (2), Warning (3) od PRVOG starta skripte (i pre restarta)
    $since = $script:RunStart
    if ($script:State -and $script:State.FirstStart) {
        $since = [datetime]$script:State.FirstStart
    }
    # Datumi svuda u formatu yyyy-MM-dd HH:mm:ss - ne zavisi od kulture sistema
    $sinceText = $since.ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($logName in @('System', 'Application')) {
        $csvPath = Join-Path -Path $diagDir -ChildPath "Events_$logName.csv"
        try {
            # Prvo u promenljivu: Export-Csv u istom pipeline-u bi napravio prazan fajl i kad dogadjaja nema
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Level = 1, 2, 3; StartTime = $since } -ErrorAction Stop)
            $events |
                Select-Object -Property @{ Name = 'TimeCreated'; Expression = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
                    LevelDisplayName, ProviderName, Id, Message |
                Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Event Viewer ($logName) izvezen: $($events.Count) dogadjaja od $sinceText"
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Write-Log -Message "Event Viewer ($logName): nema dogadjaja od $sinceText"
            }
            else {
                Write-Log -Level WARN -Message "Event Viewer ($logName) nije izvezen: $($_.Exception.Message)"
            }
        }
    }

    # 3. Osnovni podaci o sistemu
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $product  = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        $os       = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $disk     = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $mode     = 'Pravi rad'
        if ($DryRun) {
            $mode = 'DryRun'
        }
        $info = @(
            "Racunar:     $env:COMPUTERNAME"
            "Proizvodjac: $($computer.Manufacturer)"
            "Model:       $($computer.Model) / $($product.Version)"
            "Windows:     $($os.Caption) $($os.Version) (build $($os.BuildNumber))"
            # Invariant kultura: decimalna tacka bez obzira na regionalni format (posle sekcije 2 je zarez)
            ('Disk C:      {0} GB slobodno od {1} GB' -f ($disk.FreeSpace / 1GB).ToString('N1', [System.Globalization.CultureInfo]::InvariantCulture),
                ($disk.Size / 1GB).ToString('N1', [System.Globalization.CultureInfo]::InvariantCulture))
            "PowerShell:  $($PSVersionTable.PSVersion)"
            "Vreme:       $(Get-TimeInfo)"
            "Rezim:       $mode"
            'Mrezni adapteri (samo oni koji imaju drajver):'
        )
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        if ($adapters.Count -eq 0) {
            $info += '  (nijedan - mrezna kartica verovatno nema drajver)'
        }
        foreach ($adapter in $adapters) {
            $info += '  {0} | {1} | {2}' -f $adapter.Name, $adapter.InterfaceDescription, $adapter.Status
        }
        $info | Set-Content -Path (Join-Path -Path $diagDir -ChildPath 'SystemInfo.txt') -Encoding UTF8
    }
    catch {
        Write-Log -Level WARN -Message "SystemInfo nije napravljen: $($_.Exception.Message)"
    }

    # 4. Sve u jedan .zip (lakse za prenos)
    $script:DiagZip = "$diagDir.zip"
    Compress-Archive -Path (Join-Path -Path $diagDir -ChildPath '*') -DestinationPath $script:DiagZip -Force
    Write-Log -Message "Dijagnosticki paket: $script:DiagZip"
}

function Copy-LogToUsb {
    # Kopija na fles: <fles>\Logs\<BIOS serijski>_<yyyy-MM-dd_HHmm>\ (Logs\ se pravi sam ako ne postoji):
    # - SVE iz C:\ProgramData\Provisioning osim setup.lock (Logs\* u koren foldera, ostalo sa svojom putanjom);
    # - tragovi instalacije Windowsa ako postoje: Panther\setupact.log i Disk_check.txt (Check-Disk.cmd).
    # Panther\unattend.xml (kes odgovora) se NIKAD ne kopira - moze sadrzati lozinku; u logu je samo da li postoji.
    # Posle kopiranja SHA256 svakog fajla iz ProgramData. Vraca $true SAMO ako je sve kopirano i identicno -
    # tek tada sme brisanje (Invoke-LogCleanup). Fles nedostupan / read-only = $false, nista se ne brise.
    # VAZNO: od kopiranja do provere nema Write-Log - log bi se promenio i SHA256 ne bi bio isti.
    try {
        Write-Log -Message "Kopiram logove na: $UsbLogDir"
        New-Item -ItemType Directory -Path $UsbLogDir -Force -ErrorAction Stop | Out-Null

        # Prvo ovi (svaki posebno - zakljucan fajl ne sme da zaustavi ostale), da WARN udje u nas log ispod
        foreach ($file in @($PantherSetupLog, $DiskCheckLog)) {
            if (-not (Test-Path -LiteralPath $file)) {
                Write-Log -Message "Nema $file - preskacem"
                continue
            }
            try {
                if ($file -eq $DiskCheckLog) {
                    # Disk_check.txt u korenu flesa raste sa svakim racunarom - u folder racunara samo POSLEDNJI blok
                    # (poslednji "=====" zapis = ovaj racunar: fles je u njemu od WinPE-a do kraja Setup-a)
                    $allLines = @(Get-Content -LiteralPath $file -ErrorAction Stop)
                    if ($allLines.Count -eq 0) {
                        Write-Log -Message "$file je prazan - preskacem"
                        continue
                    }
                    $start = 0
                    for ($i = 0; $i -lt $allLines.Count; $i++) {
                        if ($allLines[$i].StartsWith('=====')) {
                            $start = $i
                        }
                    }
                    $block = @($allLines[$start..($allLines.Count - 1)])
                    Set-Content -LiteralPath (Join-Path -Path $UsbLogDir -ChildPath 'Disk_check.txt') -Value $block -ErrorAction Stop
                    Write-Log -Message "Kopiran poslednji blok iz $file ($($block.Count) redova od $($allLines.Count))"
                    continue
                }
                Copy-Item -LiteralPath $file -Destination $UsbLogDir -Force -ErrorAction Stop
                Write-Log -Message "Kopiran $file"
            }
            catch {
                Write-Log -Level WARN -Message "Nije kopiran ${file}: $($_.Exception.Message)"
            }
        }

        $files = @(Get-ChildItem -LiteralPath $BaseDir -Recurse -File -Force -ErrorAction Stop |
                Where-Object { $_.FullName -ne $LockFile })
        # Poslednji red u nasem logu - posle njega se log kopira i proverava
        Write-Log -Message "Kopiram $($files.Count) fajlova iz $BaseDir i proveravam SHA256"
    }
    catch {
        Write-Log -Level WARN -Message "Kopiranje logova na fles nije uspelo: $($_.Exception.Message)"
        return $false
    }

    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($BaseDir.Length).TrimStart('\')
        if ($relative -like 'Logs\*') {
            $relative = $relative.Substring(5)
        }
        $target = Join-Path -Path $UsbLogDir -ChildPath $relative
        try {
            $targetDir = Split-Path -Path $target -Parent
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
            }
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                $failed.Add("$relative (SHA256 razlika)")
            }
        }
        catch {
            $failed.Add("$relative ($($_.Exception.Message))")
        }
    }
    if ($failed.Count -gt 0) {
        # Nista se nece brisati - zato ovde sme Write-Log (lokalni log ostaje na racunaru)
        Write-Log -Level WARN -Message "Kopija logova na fles NIJE potpuna ($($failed.Count)): $($failed -join '; ')"
        return $false
    }
    return $true
}

function Add-LogsShortcut {
    # Precica "Provisioning LOGOVI.lnk" na desktopu ka C:\ProgramData\Provisioning (kad logovi ostaju na racunaru).
    # Vraca dodatak za tekst u izvestaju.
    try {
        $shell    = New-Object -ComObject 'WScript.Shell'
        $shortcut = $shell.CreateShortcut($LogsShortcut)
        $shortcut.TargetPath  = $BaseDir
        $shortcut.Description = 'Provisioning logovi (ostavljeni na racunaru)'
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $LogsShortcut)) {
            throw 'precica nije snimljena'
        }
        return ' (precica na desktopu)'
    }
    catch {
        Write-Host "Precica na desktopu nije napravljena: $($_.Exception.Message)" -ForegroundColor Red
        return " (precica NIJE napravljena: $($_.Exception.Message))"
    }
}

function Invoke-LogCleanup {
    # Na KRAJU provisioning-a (izvestaj napravljen, nije DryRun, nema planiranog restarta):
    # - bilo je gresaka (sekcija Failed) ili kopija nije potpuna -> NISTA se ne brise, precica na desktopu;
    #   state.json ostaje, pa ponovni Start.bat ponavlja samo Failed sekcije i posle uspeha brise sve sam;
    # - sve proslo i kopija potpuna (SHA256) -> brise se ceo C:\ProgramData\Provisioning i precica (ako postoji),
    #   uz proveru da ih vise nema. Na racunaru ostaje samo izvestaj na desktopu.
    # Vraca tekst za izvestaj (sekcija LOGOVI). Posle brisanja nema Write-Log - log fajl vise ne postoji.
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Copied,

        [Parameter(Mandatory = $true)]
        [bool]$HadErrors
    )
    if (-not $Copied) {
        $script:LogsKept    = $true
        $script:LogsWarning = $true
        return "Logovi NISU kopirani na fles - ostaju u $BaseDir$(Add-LogsShortcut)"
    }
    if ($HadErrors) {
        $script:LogsKept = $true
        return "Na flesu: $UsbLogDir; na racunaru: ostavljeno zbog gresaka$(Add-LogsShortcut) - posle uspesnog ponovnog pokretanja Start.bat brise se samo"
    }

    try {
        Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Brisanje $BaseDir nije uspelo: $($_.Exception.Message)" -ForegroundColor Red
    }
    # Precica iz ranijeg pokretanja sa greskama
    if (Test-Path -LiteralPath $LogsShortcut) {
        try {
            Remove-Item -LiteralPath $LogsShortcut -Force -ErrorAction Stop
        }
        catch {
            Write-Host "Brisanje precice nije uspelo: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    # Provera citanjem - odlucuje stvarno stanje
    $left = @()
    if (Test-Path -LiteralPath $BaseDir) {
        $left += "folder - rucno: rd /s /q `"$BaseDir`""
    }
    if (Test-Path -LiteralPath $LogsShortcut) {
        $left += "precica - rucno: del `"$LogsShortcut`""
    }
    if ($left.Count -gt 0) {
        $script:LogsKept    = $true
        $script:LogsWarning = $true
        return "Na flesu: $UsbLogDir; na racunaru: brisanje NIJE uspelo ($($left -join '; '))"
    }
    return "Na flesu: $UsbLogDir; na racunaru: obrisani posle provere (SHA256)"
}

function Copy-ReportToUsb {
    # Upisuje status logova u izvestaj (sekcija LOGOVI; ako logovi ostaju na racunaru - i !!! na vrh),
    # pa kopira izvestaj na fles i proverava SHA256. Izvestaj je na desktopu - brisanje ProgramData ga ne dira.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )
    try {
        $content = @(Get-Content -LiteralPath $script:ReportFile -Encoding UTF8 -ErrorAction Stop |
                ForEach-Object { if ($_ -eq $LogStatusMarker) { $Status } else { $_ } })
        if ($script:LogsWarning) {
            $content = @("!!! $($Status.ToUpperInvariant()) !!!") + $content
        }
        Set-Content -LiteralPath $script:ReportFile -Value $content -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "Status logova nije upisan u izvestaj: $($_.Exception.Message)" -ForegroundColor Red
    }
    try {
        if (-not (Test-Path -LiteralPath $UsbLogDir)) {
            throw "nema foldera $UsbLogDir"
        }
        $target = Join-Path -Path $UsbLogDir -ChildPath (Split-Path -Path $script:ReportFile -Leaf)
        Copy-Item -LiteralPath $script:ReportFile -Destination $target -Force -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $script:ReportFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
            throw 'SHA256 kopije nije isti'
        }
    }
    catch {
        Write-Host "Izvestaj NIJE kopiran na fles ($($_.Exception.Message)) - ostaje na desktopu" -ForegroundColor Red
    }
}

function Complete-Setup {
    # Zavrsni koraci - izvrsavaju se UVEK (poziva se iz finally)
    $script:CurrentSection = 'Main'

    # Ciscenje (ako nije vec uradjeno pre izvestaja) - pre planiranog restarta samo vracanje zastite
    Invoke-FinalCleanup

    if ($script:Results.Count -gt 0) {
        Write-Log -Message 'Rezime sekcija:'
        foreach ($result in $script:Results) {
            # Sekunde kao string ("$(...)" koristi invariant kulturu) - -f bi broj formatirao po kulturi (0,3)
            Write-Log -Message ('  {0,-8} {1,-8} {2} s' -f $result.Section, $result.Status, "$($result.Seconds)")
        }
    }
    if ($script:RebootRequired) {
        Write-Log -Level WARN -Message "Preporucen restart racunara (nije obavezan za Setup): $($script:RebootReasons -join '; ')"
    }
    Write-Log -Message "===== Setup.ps1 KRAJ (exit code $script:ExitCode) ====="

    # Transcript se zatvara pre kopiranja, da bi fajl bio kompletan
    if ($script:TranscriptOn) {
        try {
            Stop-Transcript | Out-Null
            $script:TranscriptOn = $false
        }
        catch {
            Write-Log -Level WARN -Message "Stop-Transcript nije uspeo: $($_.Exception.Message)"
        }
    }

    if ($script:Errors.Count -gt 0) {
        try {
            Export-DiagnosticPackage
        }
        catch {
            Write-Log -Level WARN -Message "Dijagnosticki paket nije napravljen: $($_.Exception.Message)"
        }
    }
    $copied = Copy-LogToUsb
    Unlock-Setup

    # Brisanje logova sa racunara - SAMO na kraju provisioning-a (izvestaj napravljen u ovom pokretanju),
    # ne u DryRun-u i ne pred planiran restart (state.json i Resume.ps1 trebaju nastavku).
    if ($script:ReportFile -and -not $DryRun -and -not $script:RestartPlanned) {
        # Greske: neka sekcija Failed u state-u (i iz ranijih pokretanja) ili greska u ovom pokretanju
        $failedSections = @($SectionMap.Keys | Where-Object { (Get-SectionStatus -Name $_) -eq 'Failed' })
        $hadErrors = ($failedSections.Count -gt 0 -or $script:Errors.Count -gt 0)
        $logStatus = Invoke-LogCleanup -Copied $copied -HadErrors $hadErrors
        Copy-ReportToUsb -Status $logStatus
        if ($script:LogsWarning) {
            $script:ReportWarnings.Add("!!! $($logStatus.ToUpperInvariant()) !!!")
        }
        else {
            Write-Host $logStatus -ForegroundColor Yellow
        }
    }
    elseif (-not $copied) {
        Write-Host "Logovi NISU kopirani na fles - ostaju u $BaseDir" -ForegroundColor Red
    }

    # Na ekranu crveno (log je vec zatvoren): upozorenja iz izvestaja (ukljucuje ciscenje) ili samo ciscenje
    if ($script:ReportWarnings.Count -gt 0) {
        Write-Host ''
        foreach ($warning in $script:ReportWarnings) {
            Write-Host $warning -ForegroundColor Red
        }
    }
    else {
        foreach ($warning in $script:CleanupWarnings) {
            Write-Host "!!! CISCENJE: $warning" -ForegroundColor Red
        }
    }
    if ($script:ReportFile) {
        Write-Host "Izvestaj: $script:ReportFile" -ForegroundColor Yellow
    }
}

# ============================================================================
#  SEKCIJA 2: REGION (vremenska zona, format, home location, tastature)
# ============================================================================

# Ciljevi (Srbija) - iste vrednosti su i u autounattend.xml (TimeZone, InputLocale, UserLocale)
$RegionTimeZoneId = 'Central Europe Standard Time'
$RegionCulture    = 'sr-Latn-RS'
$RegionGeoId      = 271                             # Srbija (proverava se po imenu)
$RegionLanguages  = @('sr-Latn-RS', 'sr-Cyrl-RS')   # dodaju se POSLE engleskog (UI) jezika
$UsKeyboardLayout = '00000409'                      # KLID rasporeda tastature "US"

function Format-LanguageList {
    # Spisak jezika kao jedan red teksta, npr. "en-GB[0809:00000409] sr-Latn-RS[241A:0000081A]".
    # Sluzi za log i za poredjenje "trenutno" i "cilj".
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$LanguageList
    )
    $parts = foreach ($language in $LanguageList) {
        '{0}[{1}]' -f $language.LanguageTag, ($language.InputMethodTips -join ',')
    }
    return ($parts -join ' ')
}

function Invoke-RegionSection {
    # Format, home location i tastature su PO KORISNIKU (HKCU): menjamo ih za korisnika koji
    # pokrece skriptu, pa ih na kraju kopiramo na Welcome screen i nove korisnike.
    Write-Log -Message "Korisnik cija se podesavanja menjaju: $env:USERDOMAIN\$env:USERNAME"

    # UI jezik se ne menja (resava se izborom ISO-a) - ostaje prvi u spisku, ali sa US tastaturom.
    # Oznaka tastature je "LANGID:KLID"; LANGID = LCID jezika kao hex sa 4 cifre (en-GB: 2057 = 0809).
    $uiLanguage = (Get-UICulture).Name
    $uiLangId   = '{0:X4}' -f ([System.Globalization.CultureInfo]$uiLanguage).LCID
    $usInputTip = '{0}:{1}' -f $uiLangId, $UsKeyboardLayout
    Write-Log -Message "UI jezik: $uiLanguage (ostaje prvi u spisku, tastatura $usInputTip = US)"

    # 1. Vremenska zona (vazi za ceo racunar)
    Invoke-Step -Name 'Vremenska zona' -Action {
        $current = (Get-TimeZone).Id
        if ($current -eq $RegionTimeZoneId) {
            Write-Log -Message "Vec podeseno: $current"
            return
        }
        Invoke-Change -Description "Vremenska zona: $current -> $RegionTimeZoneId" -Action {
            Set-TimeZone -Id $RegionTimeZoneId
            # .NET pamti zonu u kesu procesa - bez ovoga bi Get-Date i Get-TimeZone vracali staru zonu
            [System.TimeZoneInfo]::ClearCachedData()
        }
        Assert-Setting -Name 'Vremenska zona' -Actual (Get-TimeZone).Id -Expected $RegionTimeZoneId
    }

    # 2. Jezici i tastature (po korisniku) - PRE formata: Set-WinUserLanguageList vraca regionalni format
    # na jezik prikaza (test B, sesija 1: sr-Latn-RS -> en-US odmah posle izmene tastatura).
    # Cilj: [UI jezik + US] [sr-Latn-RS + srpska latinica] [sr-Cyrl-RS + srpska cirilica].
    # Prva tastatura prvog jezika je podrazumevana - zato je US podrazumevana (dogovor).
    Invoke-Step -Name 'Jezici i tastature' -Action {
        $currentText = Format-LanguageList -LanguageList (Get-WinUserLanguageList)

        $target = New-WinUserLanguageList -Language $uiLanguage
        $target[0].InputMethodTips.Clear()
        $target[0].InputMethodTips.Add($usInputTip)
        foreach ($language in $RegionLanguages) {
            # Srpski jezici dobijaju svoje podrazumevane tastature
            $target.Add($language)
        }
        $targetText = Format-LanguageList -LanguageList $target

        Write-Log -Message "Trenutno: $currentText"
        if ($currentText -eq $targetText) {
            Write-Log -Message 'Vec podeseno'
            return
        }
        Invoke-Change -Description "Jezici i tastature -> $targetText" -Action {
            Set-WinUserLanguageList -LanguageList $target -Force
        }
        Assert-Setting -Name 'Jezici i tastature' -Actual (Format-LanguageList -LanguageList (Get-WinUserLanguageList)) -Expected $targetText
    }

    # 3. Regionalni format (po korisniku).
    # Get-Culture vraca kulturu sa kojom je OVAJ proces krenuo, pa citamo registry - tu Set-Culture upisuje.
    $intlKey = 'HKCU:\Control Panel\International'
    Invoke-Step -Name 'Regionalni format' -Action {
        $current = (Get-ItemProperty -Path $intlKey -Name 'LocaleName').LocaleName
        if ($current -eq $RegionCulture) {
            Write-Log -Message "Vec podeseno: $current"
            return
        }
        Invoke-Change -Description "Regionalni format: $current -> $RegionCulture" -Action {
            Set-Culture -CultureInfo $RegionCulture
        }
        Assert-Setting -Name 'Regionalni format' -Actual (Get-ItemProperty -Path $intlKey -Name 'LocaleName').LocaleName -Expected $RegionCulture
    }

    # 4. Home location (po korisniku)
    Invoke-Step -Name 'Home location' -Action {
        $current = Get-WinHomeLocation
        if ($current.GeoId -eq $RegionGeoId) {
            Write-Log -Message "Vec podeseno: $($current.HomeLocation) (GeoId $($current.GeoId))"
            return
        }
        Invoke-Change -Description "Home location: $($current.HomeLocation) (GeoId $($current.GeoId)) -> GeoId $RegionGeoId" -Action {
            Set-WinHomeLocation -GeoId $RegionGeoId
        }
        $after = Get-WinHomeLocation
        Assert-Setting -Name 'Home location (GeoId)' -Actual $after.GeoId -Expected $RegionGeoId
        # Dodatna provera da je GeoId 271 zaista Srbija
        if (-not $DryRun) {
            if ($after.HomeLocation -notlike '*Serbia*') {
                throw "GeoId $RegionGeoId nije Srbija nego '$($after.HomeLocation)' - ispraviti `$RegionGeoId"
            }
            Write-Log -Message "Home location sada: $($after.HomeLocation)"
        }
    }

    # 5. Kopiranje na Welcome screen i nove korisnike - POSLEDNJE, jer kopira trenutno stanje
    Invoke-Step -Name 'Kopiranje na Welcome screen i nove korisnike' -Action {
        if (-not (Get-Command -Name 'Copy-UserInternationalSettingsToSystem' -ErrorAction SilentlyContinue)) {
            throw 'Copy-UserInternationalSettingsToSystem ne postoji na ovom Windowsu (potreban Windows 11)'
        }
        # Kopira se stanje korisnika - ako format nije cilj (npr. vratio ga je neki korak), ne kopiramo pogresno
        $userCulture = (Get-ItemProperty -Path $intlKey -Name 'LocaleName').LocaleName
        if (-not $DryRun -and $userCulture -ne $RegionCulture) {
            throw "Format korisnika je '$userCulture', ocekivano '$RegionCulture' - ne kopiram na Welcome screen"
        }
        Invoke-Change -Description 'Kopiram format, home location i tastature na Welcome screen i nove korisnike' -Action {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
            Add-RebootRecommendation -Reason 'Region: Welcome screen prikazuje nova regionalna podesavanja tek posle restarta'
        }
        # Welcome screen koristi HKU\.DEFAULT - tu proveravamo format
        $welcomeKey = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International'
        Assert-Setting -Name 'Welcome screen format' -Actual (Get-ItemProperty -Path $welcomeKey -Name 'LocaleName').LocaleName -Expected $RegionCulture
        if (-not $DryRun) {
            Write-Log -Message 'Welcome screen prikazuje nova podesavanja posle restarta; novi korisnici ih dobijaju pri prvom logovanju'
        }
    }
}

# ============================================================================
#  SEKCIJA 3: NETWORK (internet, mrezni drajver sa flesa, sat)
# ============================================================================

# Podesavanja sekcije 3
$NetworkDriverDir    = Join-Path -Path $PSScriptRoot -ChildPath 'Drivers\Network'
$InternetTestUrl     = 'http://www.msftconnecttest.com/connecttest.txt'   # isti URL koristi Windows (NCSI)
$InternetTestText    = 'Microsoft Connect Test'
$InternetFallbackUrl = 'https://www.microsoft.com'                         # ako je NCSI URL blokiran
$InternetAttempts    = 6
$InternetDelaySec    = 10
$ClockMaxSkewSec     = 300    # 5 min: granica za HTTPS sertifikate i Kerberos (domen)

function Test-Internet {
    # Jedna provera interneta. Vraca objekat: Ok, Url, ServerTimeUtc (vreme servera iz HTTP zaglavlja Date).
    # Invoke-WebRequest u PS 5.1 MORA imati -UseBasicParsing (bez toga trazi Internet Explorer engine).
    $ProgressPreference = 'SilentlyContinue'
    foreach ($url in @($InternetTestUrl, $InternetFallbackUrl)) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($url -eq $InternetTestUrl -and "$($response.Content)".Trim() -ne $InternetTestText) {
                Write-Log -Level WARN -Message "Neocekivan odgovor sa $url (captive portal ili proxy?)"
                continue
            }
            $serverTime = $null
            if ($response.Headers['Date']) {
                $serverTime = [System.DateTimeOffset]::Parse($response.Headers['Date'], [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            }
            return [pscustomobject]@{ Ok = $true; Url = $url; ServerTimeUtc = $serverTime }
        }
        catch {
            Write-Log -Message "Nema odgovora sa $url : $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Ok = $false; Url = $null; ServerTimeUtc = $null }
}

function Wait-Internet {
    # Vise pokusaja sa pauzom - posle drajvera/kabla adapteru treba vremena za link i DHCP adresu
    param(
        [Parameter(Mandatory = $true)]
        [int]$Attempts,

        [Parameter(Mandatory = $true)]
        [int]$DelaySeconds
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        $result = Test-Internet
        if ($result.Ok) {
            Write-Log -Message "Internet OK (pokusaj $i/$Attempts, $($result.Url))"
            return $result
        }
        if ($i -lt $Attempts) {
            Write-Log -Message "Nema interneta (pokusaj $i/$Attempts) - cekam $DelaySeconds s"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $result
}

function Get-ClockSkew {
    # Razlika lokalnog sata prema serveru u sekundama (+ = lokalni sat zuri, - = kasni).
    # Meri se preko HTTP zaglavlja Date, pa radi i kad je NTP (UDP 123) blokiran. $null ako merenje ne uspe.
    $result = Test-Internet
    if (-not $result.Ok -or -not $result.ServerTimeUtc) {
        return $null
    }
    return [math]::Round(((Get-Date).ToUniversalTime() - $result.ServerTimeUtc).TotalSeconds)
}

function Get-BrokenNetworkDevice {
    # Mrezni uredjaji bez drajvera ili sa greskom: PCI klasa 02 (CC_0200 Ethernet, CC_0280 Wi-Fi)
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 'OK' -and (($_.HardwareID -join ' ') -match 'CC_02') })
}

function Write-NetworkState {
    # Za log: adapteri, IPv4 adrese i mrezni uredjaji bez drajvera (samo cita)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    Write-Log -Message "Mrezni adapteri ($Title):"
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        Write-Log -Level WARN -Message '  (nijedan adapter sa drajverom)'
    }
    foreach ($adapter in $adapters) {
        Write-Log -Message ('  {0} | {1} | {2} | drajver {3} ({4})' -f $adapter.Name, $adapter.InterfaceDescription, $adapter.Status, $adapter.DriverVersionString, $adapter.DriverProvider)
    }
    foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notlike 'Loopback*' })) {
        # 169.254.x.x = DHCP nije odgovorio
        Write-Log -Message ('  IPv4 {0}: {1}/{2} ({3})' -f $ip.InterfaceAlias, $ip.IPAddress, $ip.PrefixLength, $ip.PrefixOrigin)
    }
    foreach ($device in (Get-BrokenNetworkDevice)) {
        Write-Log -Level WARN -Message ('  Mrezni uredjaj bez drajvera: {0} | status {1} | kod {2} | {3}' -f $device.FriendlyName, $device.Status, $device.ConfigManagerErrorCode, $device.HardwareID[0])
    }
}

function Install-FlashDriver {
    # pnputil /add-driver <folder>\*.inf /subdirs /install - paket ide u driver store i instalira se SAMO
    # na uredjaje kojima odgovara po Hardware ID-u. Koriste ga sekcija 3 (mreza) i sekcija 6 (drugi prolaz).
    # Exit kodovi (potvrdjeno u testu sekcije 3): 0 = bar jedan uredjaj dobio drajver, 259 = nijedan uredjaj
    # nije azuriran, 3010 = treba restart (Request-Restart), ostalo = greska.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder
    )
    $pattern = Join-Path -Path $Folder -ChildPath '*.inf'
    # Bez 2>&1: u PS 5.1 bi svaki red na stderr postao greska i prekinuo korak
    $output = & pnputil.exe /add-driver $pattern /subdirs /install
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        if ("$line".Trim()) {
            Write-Log -Message "  pnputil: $line"
        }
    }
    Write-Log -Message "pnputil exit code: $exitCode"
    switch ($exitCode) {
        0       { Write-Log -Message 'pnputil: OK' }
        3010    { Request-Restart -Reason 'pnputil: drajver instaliran, potreban restart (3010)' }
        259     { Write-Log -Message 'pnputil: paketi u driver store-u, nijedan uredjaj nije azuriran (nema odgovarajuceg ili je drajver vec instaliran)' }
        default { throw "pnputil vratio exit code $exitCode" }
    }
    return $exitCode
}

function Invoke-NetworkSection {
    $script:InternetOk = $false

    # 1. Stanje mreze (za log)
    Invoke-Step -Name 'Stanje mreze' -Action {
        Write-NetworkState -Title 'na pocetku'
    }

    # 2. Provera interneta
    Invoke-Step -Name 'Provera interneta' -Action {
        $result = Test-Internet
        $script:InternetOk = $result.Ok
        if ($result.Ok) {
            Write-Log -Message "Internet OK ($($result.Url))"
        }
        else {
            Write-Log -Level WARN -Message 'Nema interneta'
        }
    }

    # 3. Mrezni drajver sa flesa - kad nema interneta I (nijedan FIZICKI adapter nije Up ILI postoji
    # mrezni uredjaj bez drajvera). Ako je neki fizicki adapter Up, drajvere ne diramo - korak 4 ceka internet
    # (pnputil bi restartovao ispravnu karticu). -Physical: virtuelni adapteri (VPN, Hyper-V) se ne racunaju.
    Invoke-Step -Name 'Mrezni drajver sa flesa' -Action {
        if ($script:InternetOk) {
            Write-Log -Message 'Preskacem: internet radi'
            return
        }
        $upAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
        $broken     = @(Get-BrokenNetworkDevice)
        if ($upAdapters.Count -gt 0 -and $broken.Count -eq 0) {
            Write-Log -Message "Preskacem: adapter je Up ($(($upAdapters | ForEach-Object Name) -join ', ')) i nema uredjaja bez drajvera - samo cekam internet"
            return
        }
        Write-Log -Message "Fizickih adaptera Up: $($upAdapters.Count) | mreznih uredjaja bez drajvera: $($broken.Count)"
        $infFiles = @(Get-ChildItem -Path $NetworkDriverDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if ($infFiles.Count -eq 0) {
            Write-Log -Level WARN -Message "Na flesu nema mreznih drajvera ($NetworkDriverDir)"
            return
        }
        Write-Log -Message "Na flesu: $($infFiles.Count) INF fajlova u $NetworkDriverDir"

        $pattern = Join-Path -Path $NetworkDriverDir -ChildPath '*.inf'
        Invoke-Change -Description "pnputil /add-driver `"$pattern`" /subdirs /install" -Action {
            [void](Install-FlashDriver -Folder $NetworkDriverDir)
        }
    }

    # 4. Ponovna provera - do 6 x 10 s (dogovor). Bez interneta korak pada sa jasnom porukom.
    Invoke-Step -Name 'Ponovna provera interneta' -Action {
        if ($script:InternetOk) {
            Write-Log -Message 'Preskacem: internet radi'
            return
        }
        if ($DryRun) {
            Write-Log -Level DRYRUN -Message "Cekao bih internet do $InternetAttempts x $InternetDelaySec s"
            return
        }
        $result = Wait-Internet -Attempts $InternetAttempts -DelaySeconds $InternetDelaySec
        $script:InternetOk = $result.Ok
        Write-NetworkState -Title 'posle drajvera i cekanja'
        if (-not $result.Ok) {
            throw 'Nema interneta. Proveri kabl ili povezi Wi-Fi rucno, pa pokreni Start.bat ponovo.'
        }
    }

    # 5. Sat: Windows Time + provera razlike (<= 5 min WARN, > 5 min korak pada - dogovor)
    Invoke-Step -Name 'Sat (Windows Time)' -Action {
        if (-not $script:InternetOk) {
            Write-Log -Level WARN -Message 'Preskacem: nema interneta'
            return
        }
        $skewBefore = Get-ClockSkew
        Write-Log -Message "Razlika sata pre sinhronizacije: $skewBefore s"

        Invoke-Change -Description 'Windows Time: pokretanje servisa i w32tm /resync' -Action {
            if ((Get-Service -Name 'W32Time').Status -ne 'Running') {
                Start-Service -Name 'W32Time'
                Write-Log -Message 'Servis W32Time pokrenut'
            }
            $output = & w32tm.exe /resync
            $exitCode = $LASTEXITCODE
            # w32tm vraca 0 i kad NIJE sinhronizovao ("did not resync because no time data was available") - zato i tekst
            $synced = ($exitCode -eq 0) -and -not ("$output" -match 'did not resync')
            if (-not $synced) {
                # Odmah posle starta servis cesto jos nema podatke o vremenu - drugi pokusaj sa /rediscover
                foreach ($line in $output) {
                    if ("$line".Trim()) {
                        Write-Log -Message "  w32tm: $line"
                    }
                }
                Write-Log -Message "w32tm /resync nije sinhronizovao (exit code $exitCode) - drugi pokusaj za 5 s (/rediscover)"
                Start-Sleep -Seconds 5
                $output = & w32tm.exe /resync /rediscover
                $exitCode = $LASTEXITCODE
                $synced = ($exitCode -eq 0) -and -not ("$output" -match 'did not resync')
            }
            foreach ($line in $output) {
                if ("$line".Trim()) {
                    Write-Log -Message "  w32tm: $line"
                }
            }
            if ($synced) {
                Write-Log -Message 'w32tm: sat sinhronizovan'
            }
            else {
                # Konacnu odluku donosi izmerena razlika sata ispod (servis zna sam da ispravi sat pri startu)
                Write-Log -Level WARN -Message "w32tm nije potvrdio sinhronizaciju (exit code $exitCode) - NTP (UDP 123) je mozda blokiran"
            }
        }

        $skewAfter = Get-ClockSkew
        Write-Log -Message "Razlika sata posle: $skewAfter s"
        if ($null -eq $skewAfter) {
            Write-Log -Level WARN -Message 'Razlika sata nije izmerena (server nije vratio zaglavlje Date)'
            return
        }
        if ([math]::Abs($skewAfter) -gt $ClockMaxSkewSec) {
            if ($DryRun) {
                Write-Log -Level DRYRUN -Message "Sat odstupa $skewAfter s - u pravom radu korak pada ako sinhronizacija ne pomogne"
                return
            }
            throw "Sat odstupa $skewAfter s (granica $ClockMaxSkewSec s) - HTTPS i domenska prijava nece raditi pouzdano"
        }
        if ([math]::Abs($skewAfter) -gt 5) {
            Write-Log -Level WARN -Message "Sat odstupa $skewAfter s (ispod granice od $ClockMaxSkewSec s)"
        }
    }
}

# ============================================================================
#  SEKCIJA 4: APPS (samo Ninite sa flesa, ako ga ima - installeri iz Rucno\ se instaliraju rucno)
# ============================================================================

# Podesavanja sekcije 4
$AppsDir            = Join-Path -Path $PSScriptRoot -ChildPath 'Apps'
$NiniteFilter       = 'Ninite*.exe'
$NinitePublisher    = 'Secure By Design'   # CompanyName u .exe fajlovima Ninite-a - samo za prepoznavanje procesa
# Potpisnik Ninite-a: TACNO poredjenje samo CN-a (ne "sadrzi" - to bi proslo i za drugo ime sa istim tekstom).
# Ne ceo Subject (E=, L=, S= mogu da se promene pri obnovi), ne thumbprint (menja se pri svakoj obnovi).
# Potpis ima DigiCert timestamp - ostaje Valid i posle isteka sertifikata potpisnika (2027-01-31).
$NiniteSignerName = 'Secure By Design Inc.'
$NiniteTimeoutMin   = 60    # ukupno; 12 Java/JDK + ostalo = nekoliko GB
$NiniteIdleMin      = 5     # posle PRVOG child procesa: toliko minuta bez child procesa = kraj
$NiniteNoStartMin   = 15    # nijedan child proces za toliko minuta od starta = kraj (sve vec instalirano)
$NiniteQuietSec     = 30    # natpis "Finished" (ili UIA: svi redovi zavrseni) + toliko s bez child procesa = kraj
$NinitePollSec      = 2     # 10 s je promasio kratak 7-Zip installer (test A3)
$script:NiniteExeCache = @{}   # putanja .exe -> da li je od Ninite-a (Test-NiniteExecutable)

# Obavezne aplikacije: ako neka fali posle Ninite-a - sekcija je Failed. Ostalo iz Ninite-a je samo informativno.
# Podrazumevano PRAZNO = bez provere (svako bira svoj Ninite paket). Kljuc = ime u logu, vrednost = sablon (-like)
# za DisplayName u Uninstall kljucu. Primer:
#     'Chrome' = 'Google Chrome*'
#     '7-Zip'  = '7-Zip*'
$NiniteRequiredApps = [ordered]@{
}

function Get-InstalledProgram {
    # Snimak instaliranih programa iz Uninstall kljuceva (isti izvor kao "Installed apps").
    # Tri mesta: 64-bitni, 32-bitni (WOW6432Node) i programi samo za ovog korisnika (HKCU).
    $sources = [ordered]@{
        'HKLM64' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM32' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU'   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    }
    foreach ($hive in $sources.Keys) {
        Get-ItemProperty -Path $sources[$hive] -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            ForEach-Object {
                [pscustomobject]@{
                    Name    = "$($_.DisplayName)".Trim()
                    Version = "$($_.DisplayVersion)".Trim()
                    Hive    = $hive
                }
            }
    }
}

function Get-DescendantProcess {
    # Svi potomci (deca, unuci...) zadatih procesa, nastali posle $Since.
    # $Since stiti od PID-a koji je Windows ponovo dodelio: stari proces sa istim ParentProcessId nije nas.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$AllProcesses,

        [Parameter(Mandatory = $true)]
        [int[]]$RootIds,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )
    $result = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $queue  = New-Object -TypeName 'System.Collections.Generic.Queue[int]'
    $seen   = New-Object -TypeName 'System.Collections.Generic.HashSet[int]'
    foreach ($id in $RootIds) {
        $queue.Enqueue($id)
    }
    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        foreach ($process in $AllProcesses) {
            if ($process.ParentProcessId -eq $parentId -and $process.CreationDate -ge $Since -and
                $RootIds -notcontains $process.ProcessId -and $seen.Add([int]$process.ProcessId)) {
                $result.Add($process)
                $queue.Enqueue([int]$process.ProcessId)
            }
        }
    }
    return $result
}

function Test-NiniteExecutable {
    # Da li je .exe od Ninite-a (CompanyName iz verzije fajla). Rezultat se pamti po putanji - poziva se svakih 10 s.
    param(
        [string]$Path
    )
    if (-not $Path) {
        return $false
    }
    if (-not $script:NiniteExeCache.ContainsKey($Path)) {
        $company = ''
        try {
            $company = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.CompanyName
        }
        catch {
            $company = ''
        }
        $script:NiniteExeCache[$Path] = ("$company" -like "*$NinitePublisher*")
    }
    return $script:NiniteExeCache[$Path]
}

function Get-NiniteRootProcess {
    # Ninite procesi: onaj koji smo pokrenuli + svaki proces nastao posle starta cije se ime poklapa
    # sa "ninite*" ILI ciji je .exe od izdavaca Ninite-a (za slucaj da se Ninite pokrene pod drugim imenom)
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$AllProcesses,

        [Parameter(Mandatory = $true)]
        [int]$LaunchedId,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )
    return @($AllProcesses | Where-Object {
            $_.ProcessId -eq $LaunchedId -or
            ($_.CreationDate -ge $Since -and ($_.Name -like 'ninite*' -or (Test-NiniteExecutable -Path $_.ExecutablePath)))
        })
}

function Read-NiniteWindow {
    # UI Automation: cita prozor Ninite-a - naslov i redove liste (svaki red = niz celija "aplikacija", "status").
    # Ne baca gresku: greska ide u polje Error. Ako lista nije nadjena, Fallback ima elemente sa tekstom.
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$ProcessIds
    )
    $result = [pscustomobject]@{
        Titles   = New-Object -TypeName 'System.Collections.Generic.List[string]'
        Rows     = New-Object -TypeName 'System.Collections.Generic.List[object]'
        Fallback = New-Object -TypeName 'System.Collections.Generic.List[string]'
        Error    = $null
    }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $element  = [System.Windows.Automation.AutomationElement]
        $scope    = [System.Windows.Automation.TreeScope]
        $listCond = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $element::ControlTypeProperty, ([System.Windows.Automation.ControlType]::ListItem)
        foreach ($id in $ProcessIds) {
            $pidCond = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $element::ProcessIdProperty, $id
            foreach ($window in $element::RootElement.FindAll($scope::Children, $pidCond)) {
                $result.Titles.Add("$($window.Current.Name)")
                $items = $window.FindAll($scope::Descendants, $listCond)
                foreach ($item in $items) {
                    # Red liste: ime stavke + tekst svake kolone (deca stavke)
                    $cells = @($item.Current.Name)
                    foreach ($cell in $item.FindAll($scope::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
                        if ($cell.Current.Name -and $cells -notcontains $cell.Current.Name) {
                            $cells += $cell.Current.Name
                        }
                    }
                    $result.Rows.Add($cells)
                }
                if ($items.Count -eq 0) {
                    # Lista nije nadjena - pamtimo sve elemente sa tekstom (da vidimo kako je prozor gradjen)
                    foreach ($child in $window.FindAll($scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
                        if ($child.Current.Name -and $result.Fallback.Count -lt 100) {
                            $result.Fallback.Add(('[{0}] {1}' -f $child.Current.ControlType.ProgrammaticName, $child.Current.Name))
                        }
                    }
                }
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Get-NiniteRowState {
    # Stanje jednog reda Ninite liste po tekstu statusa:
    # Active = jos radi, Done = zavrseno (OK / Skipped / Failed), Unknown = status nije prepoznat
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Cells
    )
    if (@($Cells | Where-Object { "$_" -match '^(Downloading|Installing|Waiting|Unpacking|Verifying|Checking|Preparing|Retrying)' }).Count -gt 0) {
        return 'Active'
    }
    if (@($Cells | Where-Object { "$_" -match '^(OK|Skipped|Failed|Error)' }).Count -gt 0) {
        return 'Done'
    }
    return 'Unknown'
}

function Get-NiniteUiaSummary {
    # Jedan red teksta za log + brojevi po stanju. AllDone = postoji bar jedan red i SVI su prepoznati kao Done.
    param(
        [Parameter(Mandatory = $true)]
        [object]$Window
    )
    if ($Window.Error) {
        return [pscustomobject]@{ Text = "UIA greska: $($Window.Error)"; AllDone = $false }
    }
    $states = @($Window.Rows | ForEach-Object { Get-NiniteRowState -Cells $_ })
    $active  = @($states | Where-Object { $_ -eq 'Active' }).Count
    $done    = @($states | Where-Object { $_ -eq 'Done' }).Count
    $unknown = @($states | Where-Object { $_ -eq 'Unknown' }).Count
    $text = 'UIA: "{0}" | redova {1}: Done {2}, Active {3}, Unknown {4}' -f ($Window.Titles -join '" / "'), $states.Count, $done, $active, $unknown
    if ($states.Count -eq 0) {
        $text = 'UIA: "{0}" | lista nije procitana (elemenata sa tekstom: {1})' -f ($Window.Titles -join '" / "'), $Window.Fallback.Count
    }
    return [pscustomobject]@{
        Text    = $text
        AllDone = ($states.Count -gt 0 -and $done -eq $states.Count)
    }
}

function Read-NiniteWin32Text {
    # Win32: tekst svih kontrola u prozorima zadatih procesa ("[klasa] tekst").
    # Tekst kontrole u DRUGOM procesu GetWindowText ne vraca (samo naslov prozora) - zato WM_GETTEXT
    # preko SendMessageTimeout (500 ms; zaglavljen prozor ne zaledjuje skriptu). Greska ide kao jedan red teksta.
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$ProcessIds
    )
    try {
        if (-not ('Provisioning.WindowText' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Provisioning {
    public static class WindowText {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);

        private const uint WM_GETTEXT = 0x000D;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        private static string Describe(IntPtr hWnd) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(hWnd, cls, cls.Capacity);
            StringBuilder text = new StringBuilder(1024);
            IntPtr result;
            SendMessageTimeout(hWnd, WM_GETTEXT, (IntPtr)text.Capacity, text, SMTO_ABORTIFHUNG, 500, out result);
            return "[" + cls.ToString() + "] " + text.ToString();
        }

        public static List<string> GetTexts(uint[] processIds) {
            HashSet<uint> wanted = new HashSet<uint>(processIds);
            List<IntPtr> tops = new List<IntPtr>();
            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (wanted.Contains(pid) && IsWindowVisible(hWnd)) { tops.Add(hWnd); }
                return true;
            }, IntPtr.Zero);

            List<string> lines = new List<string>();
            foreach (IntPtr top in tops) {
                lines.Add("TOP " + Describe(top));
                // Samo vidljive kontrole: skrivena labela (npr. "Finished" pripremljena unapred) ne sme da okine kraj
                EnumChildWindows(top, delegate (IntPtr hWnd, IntPtr lParam) {
                    if (IsWindowVisible(hWnd)) {
                        string line = Describe(hWnd);
                        if (!line.EndsWith("] ")) { lines.Add(line); }
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return lines;
        }
    }
}
'@
        }
        $pids = [uint32[]]@($ProcessIds | ForEach-Object { [uint32]$_ })
        return @([Provisioning.WindowText]::GetTexts($pids))
    }
    catch {
        return @("Win32 greska: $($_.Exception.Message)")
    }
}

function Wait-NiniteFinish {
    # Ceka kraj Ninite-a. Besplatni Ninite nema /silent i prozor ostaje otvoren - zato kraj prepoznajemo sami:
    #   Finished - glavni signal: tekst u prozoru (Win32 ili UIA) pocinje sa "Finished" + $NiniteQuietSec s bez child procesa
    #   UiaDone - UIA: svi redovi u prozoru su OK/Skipped/Failed i nema child procesa $NiniteQuietSec s
    #   Idle    - rezerva: bio je bar jedan child proces (installer), a sada ih nema $NiniteIdleMin minuta
    #   NoStart - rezerva: za $NiniteNoStartMin minuta nije bilo nijednog child procesa
    #   Exited  - Ninite se sam zatvorio
    #   Timeout - $NiniteTimeoutMin minuta ukupno
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )
    $timer      = [System.Diagnostics.Stopwatch]::StartNew()
    $childSeen  = $false
    $idleSince  = 0.0          # sekunda (od starta) od koje nema child procesa
    $longestGap = 0.0          # najduza pauza IZMEDJU installera - govori da li je $NiniteIdleMin dovoljno
    $lastNames  = $null
    $lastUiaText = $null
    $lastWindow = $null        # poslednji uspesno procitan prozor (za tabelu u logu i kad Ninite izadje)
    $lastTexts  = @()          # poslednji tekstovi iz prozora (Win32 + UIA) - u log na kraju, ceo spisak
    $lastTextLine = $null
    $nextBeat   = 300
    $rootIds    = @($Process.Id)
    $reason     = $null

    while (-not $reason) {
        $all   = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
        $roots = Get-NiniteRootProcess -AllProcesses $all -LaunchedId $Process.Id -Since $Since
        $now   = $timer.Elapsed.TotalSeconds

        # Proces koji smo pokrenuli proveravamo i preko .NET objekta (pouzdano i kad CIM upit ne uspe)
        if ($roots.Count -eq 0 -and -not $Process.HasExited) {
            $roots = @([pscustomobject]@{ ProcessId = $Process.Id })
        }
        if ($roots.Count -eq 0) {
            $reason = 'Exited'
            break
        }
        $rootIds  = @($roots | ForEach-Object { [int]$_.ProcessId })
        $children = Get-DescendantProcess -AllProcesses $all -RootIds $rootIds -Since $Since

        # U log samo kad se spisak procesa promeni
        $names = (@($children | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '
        if ($names -ne $lastNames) {
            $display = $names
            if (-not $display) {
                $display = '(nema)'
            }
            Write-Log -Message ('  [{0} min] Ninite PID {1} | child procesi: {2}' -f [math]::Round($now / 60, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture), ($rootIds -join ','), $display)
            $lastNames = $names
        }

        # Prozor Ninite-a (UI Automation) - u log samo kad se sazetak promeni
        $window = Read-NiniteWindow -ProcessIds $rootIds
        $uia    = Get-NiniteUiaSummary -Window $window
        if ($window.Rows.Count -gt 0) {
            $lastWindow = $window
        }
        if ($uia.Text -ne $lastUiaText) {
            Write-Log -Message "  $($uia.Text)"
            $lastUiaText = $uia.Text
        }

        # Tekst iz prozora (Win32 kontrole + UIA elementi + naslovi) - trazimo natpis statusa "Finished..."
        $texts = @(Read-NiniteWin32Text -ProcessIds $rootIds) + @($window.Fallback) + @($window.Titles | ForEach-Object { "[UIA naslov] $_" })
        $finished = @($texts | Where-Object { "$_" -match '\]\s*Finished' }).Count -gt 0
        $textLine = ($texts | ForEach-Object { "$_".Trim() }) -join ' || '
        if ($textLine -ne $lastTextLine) {
            # Jedan red, skracen - ceo spisak ide u log na kraju
            $short = $textLine
            if ($short.Length -gt 600) {
                $short = $short.Substring(0, 600) + ' ...'
            }
            Write-Log -Message "  Tekst prozora ($($texts.Count)): $short"
            $lastTextLine = $textLine
        }
        if ($texts.Count -gt 0) {
            $lastTexts = $texts
        }

        if ($children.Count -gt 0) {
            if ($childSeen -and ($now - $idleSince) -gt $longestGap) {
                $longestGap = $now - $idleSince
            }
            $childSeen = $true
            $idleSince = $now
        }
        elseif ($finished -and ($now - $idleSince) -ge $NiniteQuietSec) {
            $reason = 'Finished'
        }
        elseif ($uia.AllDone -and ($now - $idleSince) -ge $NiniteQuietSec) {
            $reason = 'UiaDone'
        }
        elseif ($childSeen -and ($now - $idleSince) -ge $NiniteIdleMin * 60) {
            $reason = 'Idle'
        }
        elseif (-not $childSeen -and $now -ge $NiniteNoStartMin * 60) {
            $reason = 'NoStart'
        }

        if (-not $reason -and $now -ge $NiniteTimeoutMin * 60) {
            $reason = 'Timeout'
        }
        if (-not $reason) {
            if ($now -ge $nextBeat) {
                Write-Log -Message "  Ninite radi $([math]::Round($now / 60)) min"
                $nextBeat += 300
            }
            Start-Sleep -Seconds $NinitePollSec
        }
    }
    $timer.Stop()
    return [pscustomobject]@{
        Reason     = $reason
        Minutes    = [math]::Round($timer.Elapsed.TotalMinutes, 1)
        LongestGap = [math]::Round($longestGap)
        ChildSeen  = $childSeen
        RootIds    = $rootIds
        LastWindow = $lastWindow
        LastTexts  = $lastTexts
    }
}

function Get-NiniteLeftoverWindow {
    # Posle kraja: exit code Ninite-a + svi prozori nastali posle starta koji su i dalje otvoreni (u log).
    # Vraca PID-ove onih koji su od Ninite-a (ime ili izdavac .exe-a) - njih treba zatvoriti.
    # Test A2/A3: proces koji smo pratili je izasao, a Ninite prozor je ostao i drzao Start.bat otvorenim.
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )
    if ($Process.HasExited) {
        Write-Log -Message "Ninite (PID $($Process.Id)) exit code: $($Process.ExitCode)"
    }
    $niniteIds = New-Object -TypeName 'System.Collections.Generic.List[int]'
    try {
        $windows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [System.IntPtr]::Zero } |
                Where-Object { $_.StartTime -ge $Since })
        Write-Log -Message "Otvorenih prozora nastalih posle starta Ninite-a: $($windows.Count)"
        foreach ($item in $windows) {
            $parentId = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($item.Id)" -ErrorAction SilentlyContinue).ParentProcessId
            $isNinite = ($item.ProcessName -like 'ninite*') -or (Test-NiniteExecutable -Path $item.Path)
            Write-Log -Message ('  Otvoren prozor: {0} (PID {1}, roditelj {2}, Ninite: {3}) "{4}" | {5}' -f $item.ProcessName, $item.Id, $parentId, $isNinite, $item.MainWindowTitle, $item.Path)
            if ($isNinite) {
                $niniteIds.Add($item.Id)
            }
        }
    }
    catch {
        Write-Log -Level WARN -Message "Spisak prozora nije procitan: $($_.Exception.Message)"
    }
    return $niniteIds
}

function Close-Ninite {
    # Prvo "lepo" (kao klik na X), pa tek ako ne pomogne za 15 s - Stop-Process
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$ProcessIds
    )
    foreach ($id in $ProcessIds) {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($process -and $process.MainWindowHandle -ne [System.IntPtr]::Zero) {
            [void]$process.CloseMainWindow()
        }
    }
    for ($i = 0; $i -lt 15; $i++) {
        if (-not @(Get-Process -Id $ProcessIds -ErrorAction SilentlyContinue)) {
            Write-Log -Message 'Ninite prozor zatvoren'
            return
        }
        Start-Sleep -Seconds 1
    }
    Write-Log -Level WARN -Message 'Ninite se nije zatvorio za 15 s - Stop-Process'
    Stop-Process -Id $ProcessIds -Force -ErrorAction SilentlyContinue
}

function Request-KeepAwake {
    # Dok Ninite radi, racunar ne sme da ode u sleep (dogovor: privremeno, samo dok skripta radi).
    # SetThreadExecutionState ne menja power plan - zahtev vazi dok ga ne ponistimo ili dok proces radi.
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )
    if (-not ('Provisioning.Power' -as [type])) {
        Add-Type -Namespace 'Provisioning' -Name 'Power' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
    }
    # ES_CONTINUOUS = 0x80000000 (decimalno, jer je 0x80000000 u PS 5.1 negativan int), ES_SYSTEM_REQUIRED = 1
    $flags = [uint32]2147483648
    if ($Enabled) {
        $flags = $flags -bor [uint32]1
    }
    [void][Provisioning.Power]::SetThreadExecutionState($flags)
}

function Get-NiniteCandidate {
    # Ninite na flesu: Ninite*.exe u Apps\ (i podfolderima), najnoviji; pokrece se SAMO ako je potpis Valid
    # i CN potpisnika TACNO $NiniteSignerName. Status: NoNinite (normalan izbor), Rejected, Trusted.
    # Koriste ga sekcija Apps i izvestaj (izvestaj posle restarta nema rezultat sekcije iz istog pokretanja).
    $found = @(Get-ChildItem -LiteralPath $AppsDir -Recurse -File -Filter $NiniteFilter -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending)
    $result = [pscustomobject]@{ Status = 'NoNinite'; Exe = $null; Count = $found.Count; Reason = "nema $NiniteFilter u $AppsDir"; SignatureText = '' }
    if ($found.Count -eq 0) {
        return $result
    }
    $result.Exe = $found[0]
    $signature = Get-AuthenticodeSignature -LiteralPath $found[0].FullName
    $signer = ''
    if ($signature.SignerCertificate) {
        $signer = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    }
    $stamper = '(nema)'
    if ($signature.TimeStamperCertificate) {
        $stamper = $signature.TimeStamperCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    }
    $result.SignatureText = "$($signature.Status) | CN potpisnika: $signer | timestamp: $stamper | $($signature.SignerCertificate.Subject)"
    if ($signature.Status -ne 'Valid') {
        $result.Status = 'Rejected'
        $result.Reason = "$($found[0].Name): potpis nije Valid ($($signature.Status))"
    }
    elseif ($signer -cne $NiniteSignerName) {
        $result.Status = 'Rejected'
        $result.Reason = "$($found[0].Name): potpisnik '$signer', ocekivano '$NiniteSignerName'"
    }
    else {
        $result.Status = 'Trusted'
        $result.Reason = ''
    }
    return $result
}

function Invoke-AppsSection {
    # Stanje izmedju koraka: hashtable se prenosi po referenci, pa ga koraci (child scope) mogu menjati
    $apps = @{ Ninite = $null; Before = $null; Run = $null }

    # 1. Ninite na flesu + potpis. Fles BEZ Ninite-a je normalan izbor: sekcija je Done, bez greske i bez !!!.
    Invoke-Step -Name 'Pronadji Ninite i proveri potpis' -Action {
        $apps.Ninite = Get-NiniteCandidate
        if ($apps.Ninite.Status -eq 'NoNinite') {
            Write-Log -Message "Ninite nije na flesu ($($apps.Ninite.Reason)) - aplikacije se ne instaliraju (nije greska)"
            return
        }
        if ($apps.Ninite.Count -gt 1) {
            Write-Log -Level WARN -Message "Pronadjeno $($apps.Ninite.Count) Ninite fajlova - uzimam najnoviji"
        }
        Write-Log -Message "Ninite: $($apps.Ninite.Exe.FullName) ($($apps.Ninite.Exe.Length) B, $($apps.Ninite.Exe.LastWriteTime.ToString('yyyy-MM-dd')))"
        Write-Log -Message "Potpis: $($apps.Ninite.SignatureText)"
        if ($apps.Ninite.Status -ne 'Trusted') {
            # Fles je put za malware - pokrecemo samo fajl koji je zaista potpisao Ninite
            throw "Ninite odbijen - $($apps.Ninite.Reason) - ne pokrecem ga"
        }
    }
    if (-not $apps.Ninite -or $apps.Ninite.Status -ne 'Trusted') {
        # Bez Ninite-a (normalno) ili odbijen (greska je vec zabelezena u koraku) - ostali koraci nemaju sta da rade.
        # Izvestaj sam proverava Ninite na flesu (Get-NiniteCandidate) i pise razlog.
        return
    }

    # 2. Internet - Ninite preuzima aplikacije tokom rada
    Invoke-Step -Name 'Internet' -Action {
        if (-not $script:InternetOk) {
            # Sekcija 3 nije pustena u ovom pokretanju (npr. -Section Apps) ili nije uspela
            $result = Test-Internet
            $script:InternetOk = $result.Ok
        }
        if (-not $script:InternetOk) {
            throw 'Nema interneta - Ninite ne moze da preuzme aplikacije. Prvo sekcija Network.'
        }
        Write-Log -Message 'Internet OK'
    }

    # 3. Snimak instaliranih programa PRE Ninite-a (za razliku posle)
    Invoke-Step -Name 'Snimak programa (pre)' -Action {
        $apps.Before = @(Get-InstalledProgram)
        Write-Log -Message "Instaliranih programa pre Ninite-a: $($apps.Before.Count)"
    }

    # 4. Ninite: pokreni, cekaj kraj, zatvori prozor
    Invoke-Step -Name 'Ninite (instalacija)' -Action {
        if (-not $script:InternetOk) {
            Write-Log -Level WARN -Message 'Preskacem: nema interneta'
            return
        }
        Invoke-Change -Description "Pokrecem Ninite: $($apps.Ninite.Exe.Name)" -Action {
            # Bez -Wait: Ninite prozor se nikad sam ne zatvori - kraj prepoznaje Wait-NiniteFinish
            $since = (Get-Date).AddSeconds(-2)
            Request-KeepAwake -Enabled $true
            try {
                $process  = Start-Process -FilePath $apps.Ninite.Exe.FullName -PassThru -ErrorAction Stop
                # Bez ovoga PS 5.1 kasnije vraca prazan ExitCode (handle procesa mora da se otvori odmah)
                $null = $process.Handle
                Write-Log -Message "Ninite pokrenut (PID $($process.Id)); kraj = natpis Finished + $NiniteQuietSec s bez installera, rezerva $NiniteIdleMin min bez installera, max $NiniteTimeoutMin min"
                $apps.Run = Wait-NiniteFinish -Process $process -Since $since
                Write-Log -Message ('Ninite kraj: {0} | trajanje {1} min | najduza pauza izmedju installera {2} s' -f $apps.Run.Reason, $apps.Run.Minutes.ToString([System.Globalization.CultureInfo]::InvariantCulture), $apps.Run.LongestGap)

                # Poslednje stanje prozora - status po aplikaciji (rezultat sekcije i dalje odlucuje registry)
                if ($apps.Run.LastWindow) {
                    Write-Log -Message 'Ninite prozor, poslednje procitano stanje (UI Automation):'
                    foreach ($row in $apps.Run.LastWindow.Rows) {
                        Write-Log -Message ('  [{0,-7}] {1}' -f (Get-NiniteRowState -Cells $row), ($row -join ' | '))
                    }
                }
                else {
                    Write-Log -Level WARN -Message 'UI Automation nije procitao listu Ninite prozora'
                }
                # Poslednji procitani tekst iz prozora, ceo (procitan dok je prozor jos bio otvoren)
                Write-Log -Message "Ninite prozor, poslednji procitani tekst ($(@($apps.Run.LastTexts).Count) stavki):"
                foreach ($line in $apps.Run.LastTexts) {
                    Write-Log -Message "  $line"
                }
                if ($apps.Run.Reason -ne 'Exited') {
                    Close-Ninite -ProcessIds $apps.Run.RootIds
                }
                # Ninite prozor koji je ostao (u procesu koji nismo pratili) bi drzao Start.bat otvorenim
                $leftover = @(Get-NiniteLeftoverWindow -Process $process -Since $since)
                if ($leftover.Count -gt 0) {
                    Write-Log -Level WARN -Message "Ninite prozor je i dalje otvoren (PID $($leftover -join ', ')) - zatvaram ga"
                    Close-Ninite -ProcessIds $leftover
                }
            }
            finally {
                Request-KeepAwake -Enabled $false
            }
            if ($apps.Run.Reason -eq 'Timeout') {
                throw "Ninite nije zavrsio za $NiniteTimeoutMin min - zatvoren"
            }
            if ($apps.Run.Reason -eq 'NoStart') {
                Write-Log -Level WARN -Message "Ninite za $NiniteNoStartMin min nije pokrenuo nijedan installer (sve vec instalirano?)"
            }
        }
    }

    # 5. Rezultat: razlika u Uninstall kljucevima + provera obaveznih aplikacija (samo kad je Ninite na flesu i proveren)
    Invoke-Step -Name 'Rezultat' -Action {
        $after = @(Get-InstalledProgram)

        if ($apps.Run) {
            $beforeKeys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
            foreach ($program in $apps.Before) {
                [void]$beforeKeys.Add("$($program.Name)|$($program.Version)|$($program.Hive)")
            }
            $new = @($after | Where-Object { -not $beforeKeys.Contains("$($_.Name)|$($_.Version)|$($_.Hive)") } |
                    Sort-Object -Property Name)
            Write-Log -Message "Novi ili azurirani programi posle Ninite-a: $($new.Count)"
            foreach ($program in $new) {
                Write-Log -Message ('  {0} | {1} | {2}' -f $program.Name, $program.Version, $program.Hive)
            }
        }
        elseif (-not $DryRun) {
            Write-Log -Level WARN -Message 'Ninite nije pokrenut - samo provera obaveznih aplikacija'
        }

        $missing = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($app in $NiniteRequiredApps.Keys) {
            $match = @($after | Where-Object { $_.Name -like $NiniteRequiredApps[$app] }) | Select-Object -First 1
            if ($match) {
                Write-Log -Message ('  OK    {0,-10} {1} {2}' -f $app, $match.Name, $match.Version)
            }
            else {
                Write-Log -Level WARN -Message ('  NEMA  {0,-10} (trazeno: {1})' -f $app, $NiniteRequiredApps[$app])
                $missing.Add($app)
            }
        }
        if ($DryRun) {
            Write-Log -Level DRYRUN -Message "Obaveznih aplikacija vec instalirano: $($NiniteRequiredApps.Count - $missing.Count)/$($NiniteRequiredApps.Count)"
            return
        }
        if ($missing.Count -gt 0) {
            throw "Nisu instalirane obavezne aplikacije: $($missing -join ', ')"
        }
    }
}

# ============================================================================
#  SEKCIJA 5: BROWSER (Chrome kao default za NOVE korisnike - DISM, ne politika)
# ============================================================================

# Dogovor 2026-10-23 (nacin B): Dism /Import-DefaultAppAssociations. Windows sam primeni asocijacije pri PRVOM
# logovanju novog korisnika (i sam racuna UserChoice hash), korisnik posle moze da promeni.
# Postojeci nalozi (npr. admin) NE dobijaju Chrome default - namerno (UserChoice/UCPD se ne zaobilazi).
$BrowserProgId      = 'ChromeHTML'
$BrowserAppName     = 'Google Chrome'
$BrowserIdentifiers = @('.htm', '.html', 'http', 'https')
$BrowserXmlFile     = Join-Path -Path $BaseDir -ChildPath 'DefaultAssociations.xml'
$OemAssocFile       = Join-Path -Path $env:windir -ChildPath 'System32\OEMDefaultAssociations.xml'   # ovde DISM upisuje import
$OemAssocBackup     = Join-Path -Path $BaseDir -ChildPath 'OEMDefaultAssociations_original.xml'

function Get-OemAssociation {
    # Asocijacije za nove korisnike iz OEMDefaultAssociations.xml: hashtable Identifier -> ProgId.
    # Prazno ako fajl ne postoji.
    $map = @{}
    if (Test-Path -LiteralPath $OemAssocFile) {
        $doc = New-Object -TypeName System.Xml.XmlDocument
        $doc.Load($OemAssocFile)
        foreach ($node in $doc.DocumentElement.SelectNodes('Association')) {
            $map[$node.GetAttribute('Identifier')] = $node.GetAttribute('ProgId')
        }
    }
    return $map
}

function Get-UserChoiceProgId {
    # Izbor TRENUTNOG korisnika (HKCU) za protokol (http) ili ekstenziju (.html). $null ako izbora nema.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identifier
    )
    $path = "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Identifier\UserChoice"
    if ($Identifier.StartsWith('.')) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Identifier\UserChoice"
    }
    return (Get-ItemProperty -LiteralPath $path -Name 'ProgId' -ErrorAction SilentlyContinue).ProgId
}

function Get-BrowserAssociationXml {
    # Postojeci OEM spisak (podrazumevane Windows asocijacije) + nasi redovi za Chrome.
    # DISM import ZAMENJUJE ceo spisak - bez spajanja bi novi korisnici izgubili ostale podrazumevane asocijacije.
    $doc = New-Object -TypeName System.Xml.XmlDocument
    if (Test-Path -LiteralPath $OemAssocFile) {
        $doc.Load($OemAssocFile)
    }
    else {
        [void]$doc.AppendChild($doc.CreateXmlDeclaration('1.0', 'UTF-8', $null))
        [void]$doc.AppendChild($doc.CreateElement('DefaultAssociations'))
    }
    $root = $doc.DocumentElement
    foreach ($node in @($root.SelectNodes('Association'))) {
        if ($BrowserIdentifiers -contains $node.GetAttribute('Identifier')) {
            [void]$root.RemoveChild($node)
        }
    }
    foreach ($identifier in $BrowserIdentifiers) {
        $node = $doc.CreateElement('Association')
        $node.SetAttribute('Identifier', $identifier)
        $node.SetAttribute('ProgId', $BrowserProgId)
        $node.SetAttribute('ApplicationName', $BrowserAppName)
        [void]$root.AppendChild($node)
    }
    return $doc
}

function Get-ChromeExe {
    # Putanja do chrome.exe ili $null ako Chrome nije instaliran (koriste sekcija 5 i izvestaj)
    return @(
        (Join-Path -Path $env:ProgramFiles -ChildPath 'Google\Chrome\Application\chrome.exe')
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Invoke-BrowserSection {
    # Stanje izmedju koraka (hashtable se prenosi po referenci)
    $browser = @{ Ready = $false; Installed = $true }

    # 1. Chrome mora biti instaliran (Ninite) - inace ProgId ChromeHTML ne postoji.
    # Bez Chrome-a je normalan izbor (fles bez Ninite-a ili paket bez Chrome-a): sekcija je Done, bez greske.
    Invoke-Step -Name 'Chrome instaliran' -Action {
        $chromeExe = Get-ChromeExe
        if (-not $chromeExe) {
            $browser.Installed = $false
            Write-Log -Message 'Chrome nije instaliran - default browser se ne podesava (nije greska)'
            return
        }
        if (-not (Test-Path -LiteralPath "HKLM:\SOFTWARE\Classes\$BrowserProgId")) {
            throw "Chrome postoji, ali ProgId $BrowserProgId nije registrovan"
        }
        Write-Log -Message "Chrome: $chromeExe $((Get-Item -LiteralPath $chromeExe).VersionInfo.ProductVersion) | ProgId $BrowserProgId postoji"
        $browser.Ready = $true
    }
    if (-not $browser.Installed) {
        return
    }

    # 2. Trenutno stanje (samo log): spisak za nove korisnike + izbor korisnika koji pokrece skriptu
    Invoke-Step -Name 'Trenutno stanje' -Action {
        $oem = Get-OemAssociation
        foreach ($identifier in $BrowserIdentifiers) {
            Write-Log -Message ('  {0,-6} novi korisnici: {1,-14} | {2}: {3}' -f $identifier, "$($oem[$identifier])", $env:USERNAME, "$(Get-UserChoiceProgId -Identifier $identifier)")
        }
        Write-Log -Message "Nalog $env:USERNAME ne dobija Chrome default - namerno (vazi samo za nove korisnike)"
    }

    # 3. DISM import (samo ako spisak za nove korisnike jos nema Chrome za sve 4 stavke)
    Invoke-Step -Name 'Chrome default za nove korisnike (DISM)' -Action {
        if (-not $browser.Ready) {
            Write-Log -Level WARN -Message 'Preskacem: Chrome nije spreman'
            return
        }
        $oem = Get-OemAssociation
        $missing = @($BrowserIdentifiers | Where-Object { $oem[$_] -ne $BrowserProgId })
        if ($missing.Count -eq 0) {
            Write-Log -Message "Vec podeseno: $($BrowserIdentifiers -join ', ') -> $BrowserProgId"
            return
        }
        Write-Log -Message "Treba podesiti: $($missing -join ', ') (asocijacija u OEM spisku: $($oem.Count))"

        Invoke-Change -Description "Dism /Online /Import-DefaultAppAssociations:$BrowserXmlFile ($($BrowserIdentifiers -join ', ') -> $BrowserProgId)" -Action {
            # Original cuvamo samo jednom - to je pravi Windows spisak, pre bilo kakve nase izmene
            if ((Test-Path -LiteralPath $OemAssocFile) -and -not (Test-Path -LiteralPath $OemAssocBackup)) {
                Copy-Item -LiteralPath $OemAssocFile -Destination $OemAssocBackup
                Write-Log -Message "Original sacuvan: $OemAssocBackup"
            }
            (Get-BrowserAssociationXml).Save($BrowserXmlFile)

            $output = & dism.exe /Online "/Import-DefaultAppAssociations:$BrowserXmlFile"
            $exitCode = $LASTEXITCODE
            foreach ($line in $output) {
                if ("$line".Trim()) {
                    Write-Log -Message "  dism: $line"
                }
            }
            Write-Log -Message "dism exit code: $exitCode"
            if ($exitCode -ne 0) {
                throw "dism vratio exit code $exitCode"
            }
        }

        if (-not $DryRun) {
            $after = Get-OemAssociation
            foreach ($identifier in $BrowserIdentifiers) {
                Assert-Setting -Name "Novi korisnici $identifier" -Actual "$($after[$identifier])" -Expected $BrowserProgId
            }
            Write-Log -Message 'Primenjuje se pri PRVOM logovanju svakog novog korisnika (i domenskog)'
        }
    }
}

# ============================================================================
#  SEKCIJA 6: DRIVERS (Windows Update za drajvere, drugi prolaz sa flesa)
# ============================================================================

# Dogovor 2026-10-23 (v1): svi proizvodjaci (i Lenovo) idu putem WU + Hardware ID, bez alata proizvodjaca.
# BIOS/firmware se NE instalira - samo u izvestaj "dostupno - rucno".
$DriversDir         = Join-Path -Path $PSScriptRoot -ChildPath 'Drivers'   # ceo folder (Network + sta se doda)
$DriverPassMax      = 3      # drugi prolaz: najvise toliko krugova pnputil-a
$WuRoundMax         = 3      # WU: posle instalacije nova pretraga (neki drajveri otkrivaju nove uredjaje)
$FirmwarePattern    = 'BIOS|UEFI|Firmware'
$PlaceholderVendors = @('', 'System manufacturer', 'To Be Filled By O.E.M.', 'Default string', 'O.E.M.')

function Get-ComputerIdentity {
    # Proizvodjac, model, serijski broj, BIOS - za log i izvestaj.
    # Lenovo: Model je tip masine (npr. 11DA...), citljivo ime je u Win32_ComputerSystemProduct.Version.
    $system  = Get-CimInstance -ClassName Win32_ComputerSystem
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct
    $bios    = Get-CimInstance -ClassName Win32_BIOS
    $vendor  = "$($system.Manufacturer)".Trim()
    return [pscustomobject]@{
        Manufacturer = $vendor
        Model        = "$($system.Model)".Trim()
        ProductName  = "$($product.Version)".Trim()
        Serial       = "$($bios.SerialNumber)".Trim()
        Bios         = "$($bios.SMBIOSBIOSVersion)".Trim()
        Known        = ($PlaceholderVendors -notcontains $vendor)
    }
}

function Get-MissingDriverDevice {
    # Uredjaji koji nisu OK (npr. Code 28 = nema drajvera). Code 22 = rucno iskljucen uredjaj - nije greska.
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne 'OK' -and $_.ConfigManagerErrorCode -ne 22 })
}

function Format-DeviceLine {
    # Jedan red o uredjaju: ime | klasa | kod greske | prvi Hardware ID (za rucnu pretragu)
    param(
        [Parameter(Mandatory = $true)]
        [object]$Device
    )
    $name = $Device.FriendlyName
    if (-not $name) {
        $name = '(bez imena)'
    }
    $hardwareId = @($Device.HardwareID)[0]
    if (-not $hardwareId) {
        $hardwareId = $Device.InstanceId
    }
    return '{0} | klasa {1} | kod {2} | {3}' -f $name, $Device.Class, $Device.ConfigManagerErrorCode, $hardwareId
}

$DriverSearchSites = [ordered]@{   # proizvodjac (regex nad Win32_ComputerSystem.Manufacturer) -> sajt za Google site:
    '^LENOVO'         = 'lenovo.com'
    '^DELL'           = 'dell.com'
    '^(HP|HEWLETT)'   = 'hp.com'
    '^ASUS'           = 'asus.com'
    '^ACER'           = 'acer.com'
}
$DriverCatalogUrl = 'https://www.catalog.update.microsoft.com/Search.aspx?q='

function Get-DriverSearchLine {
    # Za uredjaj bez drajvera: naziv, Hardware ID (prvi = najspecificniji) i dve linije za copy-paste
    # (Google sa sajtom proizvodjaca, Microsoft Update Catalog). Nepoznat proizvodjac: Google bez site:.
    param(
        [Parameter(Mandatory = $true)]
        [object]$Device,

        [Parameter(Mandatory = $true)]
        [object]$Computer,

        [Parameter(Mandatory = $true)]
        [int]$Number
    )
    $name = $Device.FriendlyName
    if (-not $name) {
        $name = '(bez imena)'
    }
    $hardwareId = @($Device.HardwareID)[0]
    if (-not $hardwareId) {
        $hardwareId = $Device.InstanceId
    }
    # Lenovo: citljivo ime modela je u ProductName (Win32_ComputerSystemProduct.Version), Model je tip masine
    $model = $Computer.Model
    if ($Computer.Manufacturer -match '^LENOVO' -and $Computer.ProductName) {
        $model = $Computer.ProductName
    }
    # Google: kratak ID (PCI VEN_xxxx&DEV_xxxx, USB/HID VID_xxxx&PID_xxxx) - pun ID retko ima pogodaka.
    # Ako kratkog nema (npr. ACPI\INT33A0), ide pun ID.
    $shortId = $hardwareId
    if ($hardwareId -match '(VEN|VID)_[0-9A-Z]{3,4}&(DEV|PID)_[0-9A-Z]{4}') {
        $shortId = $Matches[0]
    }
    $google = "driver $shortId"
    if ($Computer.Known) {
        $google = "$($Computer.Manufacturer) $model driver $shortId"
        foreach ($pattern in $DriverSearchSites.Keys) {
            if ($Computer.Manufacturer -match $pattern) {
                $google += " site:$($DriverSearchSites[$pattern])"
                break
            }
        }
    }
    return @(
        ('{0}. {1} | klasa {2} | kod {3}' -f $Number, $name, $Device.Class, $Device.ConfigManagerErrorCode)
        "   Hardware ID: $hardwareId"
        "   Google:  $google"
        "   Katalog: $DriverCatalogUrl$([System.Uri]::EscapeDataString($hardwareId))"
    )
}

function Add-FirmwareAvailable {
    # BIOS/firmware koji WU nudi - pamti se u state (izvestaj moze biti posle restarta)
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    $list = @(Get-StateValue -Name 'FirmwareAvailable')
    if ($list -notcontains $Title) {
        Save-StateValue -Name 'FirmwareAvailable' -Value @($list + $Title | Where-Object { $_ })
    }
}

function Invoke-WindowsUpdateDriver {
    # Windows Update preko ugradjenog COM API-ja (bez PSWindowsUpdate): trazi drajvere koji nisu instalirani,
    # BIOS/firmware samo belezi, ostalo preuzme i instalira. Ponavlja pretragu dok ima napretka ($WuRoundMax).
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = 'Provisioning Setup.ps1'
    for ($round = 1; $round -le $WuRoundMax; $round++) {
        Write-Log -Message "WU pretraga drajvera (krug $round/$WuRoundMax) - moze da traje nekoliko minuta"
        $timer  = [System.Diagnostics.Stopwatch]::StartNew()
        $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        Write-Log -Message "WU pretraga gotova za $([math]::Round($timer.Elapsed.TotalSeconds)) s: $($result.Updates.Count) drajvera"

        $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($update in $result.Updates) {
            $line = '{0} | klasa {1} | {2}' -f $update.Title, $update.DriverClass, $update.DriverHardwareID
            if ($update.Title -match $FirmwarePattern -or "$($update.DriverClass)" -eq 'Firmware') {
                Write-Log -Level WARN -Message "  BIOS/firmware - ne instaliram (dostupno - rucno): $line"
                Add-FirmwareAvailable -Title $update.Title
                continue
            }
            Write-Log -Message "  Za instalaciju: $line"
            [void]$toInstall.Add($update)
        }
        if ($toInstall.Count -eq 0) {
            Write-Log -Message 'WU: nema drajvera za instalaciju'
            return
        }
        if ($DryRun) {
            Write-Log -Level DRYRUN -Message "Uradio bih: preuzimanje i instalacija $($toInstall.Count) drajvera preko WU"
            return
        }
        # Prihvatanje licence je izmena (pamti je Windows Update) - zato tek posle DryRun provere
        foreach ($update in $toInstall) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
            }
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $download = $downloader.Download()
        Write-Log -Message "WU preuzimanje: ResultCode $($download.ResultCode) (2 = uspeh, 3 = delimicno, 4 = greska)"

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $install = $installer.Install()
        $installed = 0
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            $one = $install.GetUpdateResult($i)
            # ResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
            $level = 'INFO'
            if ($one.ResultCode -ge 4) {
                $level = 'WARN'
            }
            else {
                $installed++
            }
            Write-Log -Level $level -Message ('  {0} -> ResultCode {1}, HResult 0x{2:X8}' -f $toInstall.Item($i).Title, $one.ResultCode, $one.HResult)
        }
        Write-Log -Message "WU instalacija: $installed/$($toInstall.Count) uspesno, RebootRequired = $($install.RebootRequired)"
        if ($install.RebootRequired) {
            Request-Restart -Reason "Windows Update: $installed drajvera instalirano, potreban restart"
            return
        }
        if ($installed -eq 0) {
            throw "WU: nijedan od $($toInstall.Count) drajvera nije instaliran (vidi ResultCode/HResult iznad)"
        }
    }
}

function Invoke-DriversSection {
    # 1. Racunar - samo za log i izvestaj (v1: alat proizvodjaca se ne koristi ni za koga)
    Invoke-Step -Name 'Racunar' -Action {
        $computer = Get-ComputerIdentity
        Write-Log -Message "Proizvodjac: $($computer.Manufacturer) | model: $($computer.Model) / $($computer.ProductName) | serijski: $($computer.Serial) | BIOS: $($computer.Bios)"
        if (-not $computer.Known) {
            Write-Log -Message 'Nepoznat proizvodjac (placeholder u WMI) - normalno za racunar sastavljen od delova'
        }
        Write-Log -Message 'Alat proizvodjaca: ne koristi se u v1 - svi idu putem Windows Update + Hardware ID'
    }

    # 2. Pending reboot: Windows vec ceka restart (npr. posle installera iz sekcije 4) - restart PRE drajvera.
    # Samo jednom po provisioning-u: PendingFileRenameOperations ume da ostane i posle restarta.
    Invoke-Step -Name 'Pending reboot' -Action {
        $pending = @(Get-PendingRebootSource)
        if ($pending.Count -eq 0) {
            Write-Log -Message 'Windows ne ceka restart'
            return
        }
        if (Get-StateValue -Name 'PendingRebootHandled') {
            Write-Log -Level WARN -Message "Windows i dalje ceka restart ($($pending -join ', ')) - restart je vec uradjen jednom, nastavljam"
            return
        }
        if ($DryRun) {
            Write-Log -Level DRYRUN -Message "Uradio bih: restart pre drajvera (Windows ceka restart: $($pending -join ', '))"
            return
        }
        Save-StateValue -Name 'PendingRebootHandled' -Value $true
        Request-Restart -Reason "Windows vec ceka restart ($($pending -join ', ')) - restart pre drajvera"
    }

    # 3. Stanje pre drajvera (za log)
    Invoke-Step -Name 'Uredjaji bez drajvera (pre)' -Action {
        $missing = @(Get-MissingDriverDevice)
        Write-Log -Message "Uredjaja koji nisu OK: $($missing.Count)"
        foreach ($device in $missing) {
            Write-Log -Message "  $(Format-DeviceLine -Device $device)"
        }
    }

    # 4. Windows Update - drajveri (COM API)
    Invoke-Step -Name 'Windows Update - drajveri' -Action {
        if ($script:RestartNeeded) {
            Write-Log -Message 'Preskacem: ceka restart'
            return
        }
        if (-not $script:InternetOk) {
            $script:InternetOk = (Test-Internet).Ok
        }
        if (-not $script:InternetOk) {
            throw 'Nema interneta - Windows Update ne moze da trazi drajvere. Prvo sekcija Network.'
        }
        Invoke-WindowsUpdateDriver
    }

    # 5. Drugi prolaz: uredjaji koji i dalje nisu OK -> drajveri sa flesa (pnputil), dok ima napretka
    Invoke-Step -Name 'Drugi prolaz (drajveri sa flesa)' -Action {
        if ($script:RestartNeeded) {
            Write-Log -Message 'Preskacem: ceka restart'
            return
        }
        $infCount = @(Get-ChildItem -Path $DriversDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue).Count
        for ($pass = 1; $pass -le $DriverPassMax; $pass++) {
            $before = @(Get-MissingDriverDevice)
            if ($before.Count -eq 0) {
                Write-Log -Message 'Svi uredjaji imaju drajver'
                return
            }
            Write-Log -Message "Prolaz $pass/${DriverPassMax}: uredjaja bez drajvera $($before.Count), INF fajlova na flesu $infCount"
            if ($infCount -eq 0) {
                Write-Log -Level WARN -Message "Na flesu nema drajvera ($DriversDir) - uredjaji idu u izvestaj"
                return
            }
            if ($DryRun) {
                Write-Log -Level DRYRUN -Message "Uradio bih: pnputil /add-driver `"$DriversDir\*.inf`" /subdirs /install"
                return
            }
            $exitCode = Install-FlashDriver -Folder $DriversDir
            if ($script:RestartNeeded) {
                return
            }
            # Napredak = manje uredjaja bez drajvera. Bez napretka nema smisla ponavljati.
            $after = @(Get-MissingDriverDevice)
            Write-Log -Message "Posle prolaza ${pass}: uredjaja bez drajvera $($after.Count) (pre $($before.Count))"
            if ($exitCode -eq 259 -or $after.Count -ge $before.Count) {
                Write-Log -Message 'Nema napretka - kraj drugog prolaza'
                return
            }
        }
    }

    # 6. Sta je ostalo bez drajvera - WARN (ne greska): ide u izvestaj sa Hardware ID-om za rucnu pretragu
    Invoke-Step -Name 'Uredjaji bez drajvera (posle)' -Action {
        $missing = @(Get-MissingDriverDevice)
        if ($missing.Count -eq 0) {
            Write-Log -Message 'Svi uredjaji imaju drajver'
            return
        }
        Write-Log -Level WARN -Message "Bez drajvera je ostalo $($missing.Count) uredjaja (u izvestaju, sa Hardware ID-om):"
        foreach ($device in $missing) {
            Write-Log -Level WARN -Message "  $(Format-DeviceLine -Device $device)"
        }
    }
}

# ============================================================================
#  SEKCIJA 7: REPORT (izvestaj na desktopu + kopija na flesu)
# ============================================================================

# Dogovor: .txt bez boja, upozorenja na VRHU, VELIKIM SLOVIMA, sa !!! (crveno samo na ekranu na kraju).
# Pravi se uvek iznova i POSLE ciscenja (da pokaze i WARN-ove ciscenja). Podaci se citaju iz sistema,
# ne iz memorije - prethodne sekcije su mozda radile pre restarta.
$WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'   # ApplicationID Windows-a u SoftwareLicensingProduct

function Get-LicenseInfo {
    # Izdanje, licenca iz BIOS-a (OEM kljuc) i aktivacija. "Home u BIOS-u, instaliran Pro" ide u upozorenja.
    $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID').EditionID
    $oemKey  = "$((Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKeyDescription)".Trim()
    $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID = '$WindowsAppId' AND PartialProductKey IS NOT NULL AND LicenseIsAddon = FALSE" |
        Select-Object -First 1
    $code   = [int]$product.LicenseStatus
    $status = switch ($code) {
        0       { 'Unlicensed (nije aktiviran)' }
        1       { 'Licensed (aktiviran)' }
        2       { 'OOBGrace' }
        3       { 'OOTGrace' }
        4       { 'NonGenuineGrace' }
        5       { 'Notification' }
        6       { 'ExtendedGrace' }
        default { "nepoznato ($code)" }
    }
    return [pscustomobject]@{
        Edition   = $edition
        OemKey    = $oemKey
        Channel   = "$($product.ProductKeyChannel)"
        Activated = ($code -eq 1)
        Status    = $status
    }
}

function Get-BitLockerInfo {
    # Stanje BitLocker-a za C: (samo cita, NISTA ne menja). Windows 11 24H2+ na cistoj instalaciji moze sam
    # da ukljuci device encryption (odluka 2026-10-26: Windows default, ne diramo - u izvestaju samo informacija).
    # "Waiting for activation" = disk je sifrovan, ali bez zastitnika (ProtectionStatus Off, nema KeyProtector-a).
    # Recovery kljuc se NIKAD ne ispisuje - samo tipovi zastitnika.
    if (-not (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Text = 'BitLocker modul ne postoji na ovom Windowsu'; Encrypted = $false; Protected = $false; Waiting = $false }
    }
    $volume     = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    $protectors = @($volume.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
    $encrypted  = "$($volume.VolumeStatus)" -ne 'FullyDecrypted'
    $protected  = "$($volume.ProtectionStatus)" -eq 'On'
    $protectorText = $protectors -join ', '
    if (-not $protectorText) {
        $protectorText = '(nema)'
    }
    return [pscustomobject]@{
        Available = $true
        Text      = 'VolumeStatus {0} | ProtectionStatus {1} | sifrovano {2}% | KeyProtector: {3}' -f $volume.VolumeStatus, $volume.ProtectionStatus, $volume.EncryptionPercentage, $protectorText
        Encrypted = $encrypted
        Protected = $protected
        Waiting   = ($encrypted -and -not $protected -and $protectors.Count -eq 0)
        HasRecoveryPassword = ($protectors -contains 'RecoveryPassword')
    }
}

function Get-ProvisioningReport {
    # Sadrzaj izvestaja: Warnings (vrh, !!!) + Lines (telo). Svaki deo u svom try - greska u jednom ne rusi ceo izvestaj.
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines    = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    if ($DryRun) {
        $warnings.Add('!!! DRYRUN - NISTA NIJE MENJANO, OVO JE SAMO PROBA !!!')
    }
    # Lozinka naloga admin (podrazumevana "admin" iz autounattend.xml): stvarno stanje naloga, ne samo rezultat
    # ovog pokretanja - sa -Section je korak preskocen, a promena je mozda podesena ranije.
    $passwordState = $null
    try {
        $passwordState = Get-AdminPasswordState
    }
    catch {
        $passwordState = $null
    }
    if ($script:AdminPasswordResult -eq 'OK' -or ($passwordState -and $passwordState.MustChange)) {
        $passwordText = 'podeseno - Windows trazi novu lozinku pri sledecem logovanju'
        $warnings.Add('!!! LOZINKA NALOGA admin JE PODRAZUMEVANA ("admin") - WINDOWS TRAZI NOVU PRI SLEDECEM LOGOVANJU !!!')
    }
    elseif ($passwordState -and $passwordState.ChangedAfterInstall) {
        # Tehnicar je vec promenio lozinku (ponovno pokretanje) - informativno, bez !!!
        $passwordText = "lozinka je vec promenjena posle instalacije (PasswordLastSet $($passwordState.PasswordLastSet)) - nova se ne trazi"
    }
    else {
        $passwordText = 'NIJE podeseno'
        if ($script:AdminPasswordResult) {
            $passwordText += " ($($script:AdminPasswordResult))"
        }
        elseif ($Section) {
            $passwordText += ' (-Section: podesava se samo na kraju celog Setup-a)'
        }
        else {
            $passwordText += ' (greska - vidi log)'
        }
        $warnings.Add('!!! NALOG admin: NOVA LOZINKA PRI SLEDECEM LOGOVANJU NIJE PODESENA - AKO JE LOZINKA I DALJE "admin", PROMENI JE ODMAH: net user admin * !!!')
    }
    # Stalni podsetnici (dogovor)
    $warnings.Add('!!! RUCNO: INSTALIRAJ APLIKACIJE IZ FOLDERA Rucno\ NA FLESU (AKO IH IMA) !!!')
    $warnings.Add("!!! RUCNO: DOMAIN JOIN I PREIMENOVANJE RACUNARA (SADA: $($env:COMPUTERNAME.ToUpperInvariant())) !!!")

    $lines.Add('PROVISIONING IZVESTAJ')
    $lines.Add("Napravljen: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | racunar $env:COMPUTERNAME | korisnik $env:USERNAME")
    $lines.Add('')

    # Racunar i licenca
    $lines.Add('== RACUNAR ==')
    try {
        $computer = Get-ComputerIdentity
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $lines.Add("Proizvodjac: $($computer.Manufacturer)")
        $lines.Add("Model:       $($computer.Model) / $($computer.ProductName)")
        $lines.Add("Serijski:    $($computer.Serial)")
        $lines.Add("BIOS:        $($computer.Bios)")
        $lines.Add("Windows:     $($os.Caption) $($os.Version) (build $($os.BuildNumber))")
        $license = Get-LicenseInfo
        $lines.Add("Izdanje:     $($license.Edition) | kanal: $($license.Channel) | aktivacija: $($license.Status)")
        $lines.Add("BIOS kljuc:  $(if ($license.OemKey) { $license.OemKey } else { '(nema OEM kljuca u BIOS-u)' })")
        if ($license.OemKey -match 'Core' -and $license.Edition -eq 'Professional') {
            $warnings.Add('!!! BIOS IMA HOME LICENCU, INSTALIRAN JE PRO - PRO NIJE AKTIVIRAN (TREBA PRO LICENCA ILI UPGRADE KLJUC) !!!')
        }
        elseif (-not $license.Activated) {
            $warnings.Add("!!! WINDOWS NIJE AKTIVIRAN ($($license.Status.ToUpperInvariant())) !!!")
        }
    }
    catch {
        $lines.Add("(podaci o racunaru nisu procitani: $($_.Exception.Message))")
    }
    $lines.Add('')

    # BitLocker C: - samo stanje, INFORMATIVNO (odluka 2026-10-26: Windows default, ne diramo, bez !!! upozorenja)
    $lines.Add('== BITLOCKER (C:) ==')
    try {
        $bitlocker = Get-BitLockerInfo
        if (-not $bitlocker.Encrypted) {
            $lines.Add('Windows default: C: nije sifrovan.')
        }
        elseif (-not $bitlocker.Protected) {
            $lines.Add('Windows default (automatsko sifrovanje, zastita nije aktivirana).')
        }
        else {
            $lines.Add('Windows default: zastita aktivna (BitLocker ukljucen).')
        }
        $lines.Add($bitlocker.Text)
        if ($bitlocker.HasRecoveryPassword) {
            $lines.Add('Recovery key postoji na masini - prikaz: manage-bde -protectors -get C: (ne upisuje se u izvestaj).')
        }
    }
    catch {
        $lines.Add("(BitLocker nije procitan: $($_.Exception.Message))")
    }
    $lines.Add('')

    # Sekcije (iz state-a - pokrivaju i pokretanja pre restarta)
    $lines.Add('== SEKCIJE ==')
    foreach ($name in @($SectionMap.Keys | Where-Object { $_ -ne 'Report' })) {
        $entry = $script:State.Sections.PSObject.Properties[$name]
        if (-not $entry) {
            # Nema upisa u state (npr. DryRun ne upisuje) - rezultat OVOG pokretanja, ako postoji
            $current = @($script:Results | Where-Object { $_.Section -eq $name }) | Select-Object -Last 1
            if ($current) {
                $lines.Add(('{0,-8} {1,-14} {2,8} s  (ovo pokretanje)' -f $name, $current.Status, "$($current.Seconds)"))
                if (@('Done', 'DryRun', 'Skipped') -notcontains $current.Status) {
                    $warnings.Add("!!! SEKCIJA $($name.ToUpperInvariant()): $("$($current.Status)".ToUpperInvariant()) !!!")
                }
                continue
            }
            $lines.Add(('{0,-8} {1,-14}' -f $name, 'NotStarted'))
            $warnings.Add("!!! SEKCIJA $($name.ToUpperInvariant()): NIJE POKRENUTA !!!")
            continue
        }
        $value   = $entry.Value
        $seconds = 0.0
        if ($value.PSObject.Properties['Seconds']) {
            $seconds = [double]$value.Seconds
        }
        $lines.Add(('{0,-8} {1,-14} {2,8} s  {3}  {4}' -f $name, $value.Status, $seconds.ToString('0.0', $invariant), $value.Time, $value.Error))
        if ($value.Status -ne 'Done') {
            $warnings.Add("!!! SEKCIJA $($name.ToUpperInvariant()): $("$($value.Status)".ToUpperInvariant()) - $($value.Error) !!!")
        }
    }
    $lines.Add("Restarta tokom provisioning-a: $([int](Get-StateValue -Name 'RestartsTotal'))")
    # Restart posle Setup-a: zasto (nas razlog iz ovog pokretanja) i da li ga Windows trazi (koji kljuc) - informativno
    $pendingNow = @(Get-PendingRebootSource)
    if ($script:RebootRequired) {
        $lines.Add("Preporucen restart (nije obavezan za Setup): $($script:RebootReasons -join '; ')")
    }
    if ($pendingNow.Count -gt 0) {
        $lines.Add("Windows ceka restart (kljuc): $($pendingNow -join ', ')")
    }
    if (-not $script:RebootRequired -and $pendingNow.Count -eq 0) {
        $lines.Add('Restart posle Setup-a: nije potreban.')
    }
    $lines.Add('')

    # Programi: Ninite na flesu (isto pravilo kao sekcija 4) + obavezni programi (Uninstall kljucevi sada, ne rezultat
    # sekcije 4). Bez Ninite-a = normalan izbor (informativno, bez !!!); Ninite odbijen = !!! sa razlogom.
    $lines.Add('== PROGRAMI ==')
    try {
        $installed = @(Get-InstalledProgram)
        $ninite = Get-NiniteCandidate
        if ($ninite.Status -eq 'NoNinite') {
            $lines.Add("Ninite nije na flesu ($($ninite.Reason)) - aplikacije se ne instaliraju (normalan izbor).")
        }
        elseif ($ninite.Status -ne 'Trusted') {
            $lines.Add("Ninite ODBIJEN, nije pokrenut: $($ninite.Reason)")
            $lines.Add("Potpis: $($ninite.SignatureText)")
            $warnings.Add("!!! NINITE ODBIJEN - APLIKACIJE NISU INSTALIRANE: $($ninite.Reason) !!!")
        }
        else {
            $lines.Add("Ninite: $($ninite.Exe.Name) | potpis Valid, $NiniteSignerName")
            $missingApps = @()
            foreach ($app in $NiniteRequiredApps.Keys) {
                $match = @($installed | Where-Object { $_.Name -like $NiniteRequiredApps[$app] }) | Select-Object -First 1
                if ($match) {
                    $lines.Add(('OK    {0,-10} {1} {2}' -f $app, $match.Name, $match.Version))
                }
                else {
                    $lines.Add(('NEMA  {0,-10}' -f $app))
                    $missingApps += $app
                }
            }
            if ($missingApps.Count -gt 0) {
                $warnings.Add("!!! NIJE INSTALIRANO: $(($missingApps -join ', ').ToUpperInvariant()) !!!")
            }
        }
        $lines.Add("Ukupno instaliranih programa: $($installed.Count)")
    }
    catch {
        $lines.Add("(programi nisu procitani: $($_.Exception.Message))")
    }
    $lines.Add('')

    # Chrome default za nove korisnike (sekcija 5)
    $lines.Add('== CHROME DEFAULT (novi korisnici, ukljucujuci domenske) ==')
    $chromeInstalled = [bool](Get-ChromeExe)
    try {
        if (-not $chromeInstalled) {
            # Bez Chrome-a sekcija 5 nema sta da podesi - informativno, bez !!!
            $lines.Add('Chrome nije instaliran - default browser se ne podesava (normalan izbor).')
        }
        else {
            $oem = Get-OemAssociation
            $notSet = @($BrowserIdentifiers | Where-Object { $oem[$_] -ne $BrowserProgId })
            foreach ($identifier in $BrowserIdentifiers) {
                $lines.Add(('{0,-6} {1}' -f $identifier, "$($oem[$identifier])"))
            }
            if ($notSet.Count -gt 0) {
                $warnings.Add("!!! CHROME NIJE DEFAULT ZA NOVE KORISNIKE ($($notSet -join ', ')) !!!")
            }
            $lines.Add("Postojeci nalog $env:USERNAME ostaje na svom browseru (namerno).")
        }
    }
    catch {
        $lines.Add("(asocijacije nisu procitane: $($_.Exception.Message))")
    }
    $lines.Add('')

    # Uredjaji bez drajvera - Hardware ID + linije za rucnu pretragu (Google sa sajtom proizvodjaca, Catalog)
    $lines.Add('== UREDJAJI BEZ DRAJVERA ==')
    try {
        $devices = @(Get-MissingDriverDevice)
        if ($devices.Count -eq 0) {
            $lines.Add('Nema - svi uredjaji imaju drajver.')
        }
        else {
            $identity = Get-ComputerIdentity
            for ($i = 0; $i -lt $devices.Count; $i++) {
                foreach ($line in (Get-DriverSearchLine -Device $devices[$i] -Computer $identity -Number ($i + 1))) {
                    $lines.Add($line)
                }
            }
            $lines.Add('Napomena: ako Katalog ne nadje nista, u polju pretrage obrisi deo od &SUBSYS nadalje.')
        }
        if ($devices.Count -gt 0) {
            $warnings.Add("!!! UREDJAJA BEZ DRAJVERA: $($devices.Count) (SPISAK SA HARDWARE ID-OM U IZVESTAJU) !!!")
        }
    }
    catch {
        $lines.Add("(uredjaji nisu procitani: $($_.Exception.Message))")
    }
    $lines.Add('')

    # BIOS/firmware koji WU nudi - ne instalira se automatski (dogovor)
    $lines.Add('== BIOS / FIRMWARE (dostupno - rucno) ==')
    $firmware = @(Get-StateValue -Name 'FirmwareAvailable' | Where-Object { $_ })
    if ($firmware.Count -eq 0) {
        $lines.Add('Windows Update nije ponudio BIOS/firmware.')
    }
    foreach ($title in $firmware) {
        $lines.Add($title)
    }
    if ($firmware.Count -gt 0) {
        $lines.Add('Instalacija: Settings > Windows Update > Advanced options > Optional updates > Driver updates - NA STRUJI')
        $warnings.Add("!!! DOSTUPAN BIOS/FIRMWARE UPDATE ($($firmware.Count)) - RUCNO, NA STRUJI !!!")
    }
    $lines.Add('')

    # Ciscenje - stvarno stanje procitano POSLE ciscenja (Get-CleanupCheck), stavka po stavka
    $lines.Add('== CISCENJE ==')
    if ($DryRun) {
        $lines.Add('Nije proveravano (DryRun).')
    }
    elseif (-not $script:CleanupCheck) {
        $lines.Add('Nije proveravano - provera ciscenja nije uradjena (vidi log).')
        $warnings.Add('!!! CISCENJE NIJE PROVERENO - VIDI LOG !!!')
    }
    else {
        foreach ($check in $script:CleanupCheck) {
            $status = 'OK'
            if (-not $check.Ok) {
                $status = 'OSTALO'
            }
            $lines.Add(('{0,-6} {1} - {2}' -f $status, $check.Item, $check.Now))
        }
    }
    foreach ($warning in $script:CleanupWarnings) {
        $lines.Add("RUCNO: $warning")
        $warnings.Add("!!! CISCENJE (RUCNO): $warning !!!")
    }
    $lines.Add('')

    $lines.Add('== RUCNO PRE PREDAJE ==')
    $lines.Add('- RUCNO: instaliraj aplikacije iz foldera Rucno\ na flesu (ako ih ima). Setup ih ne pokrece i ne dira.')
    $lines.Add("- Lozinka naloga admin (podrazumevana `"admin`"): nova pri sledecem logovanju - $passwordText. Dugorocno resenje: Windows LAPS.")
    $lines.Add('- Domain join i preimenovanje racunara - rucno.')
    if ($chromeInstalled) {
        $lines.Add('- Ako korisnik koristi nalog admin: Chrome default rucno - Settings > Apps > Default apps > Google Chrome > Set default.')
    }
    $lines.Add('')
    $lines.Add('== LOGOVI ==')
    if ($DryRun) {
        $lines.Add("DryRun - nista se ne brise. Na racunaru: $BaseDir | na flesu: $UsbLogDir")
    }
    else {
        # Status (kopija + SHA256, brisanje sa racunara) upisuje Copy-ReportToUsb na kraju rada umesto ovog reda
        $lines.Add($LogStatusMarker)
    }

    return [pscustomobject]@{ Warnings = $warnings; Lines = $lines }
}

function Invoke-ReportSection {
    Invoke-Step -Name 'Izvestaj' -Action {
        $report = Get-ProvisioningReport
        # DryRun: izvestaj ide samo u folder logova (desktop se ne dira); pravi rad: desktop naloga koji pokrece skriptu
        if ($DryRun) {
            $path = Join-Path -Path $LogDir -ChildPath "Izvestaj_DRYRUN_$RunStamp.txt"
        }
        else {
            $path = Join-Path -Path ([Environment]::GetFolderPath('Desktop')) -ChildPath "Provisioning_Izvestaj_$($env:COMPUTERNAME)_$RunStamp.txt"
        }
        $content = @($report.Warnings) + @('') + @($report.Lines)
        Set-Content -LiteralPath $path -Value $content -Encoding UTF8
        $script:ReportFile = $path
        foreach ($warning in $report.Warnings) {
            $script:ReportWarnings.Add($warning)
        }
        Write-Log -Message "Izvestaj: $path ($($report.Warnings.Count) upozorenja)"
        foreach ($warning in $report.Warnings) {
            Write-Log -Level WARN -Message $warning
        }
    }

    # Chrome default za nalog koji pokrece Setup (admin): DISM vazi samo za NOVE korisnike, a UserChoice/UCPD
    # se ne zaobilazi (dogovor). Zato samo otvaramo stranu Settings-a za Chrome - tehnicar klikne "Set default".
    # Deep link (Microsoft Learn, "Launch the Default Apps settings page"): Windows 11 21H2/22H2 sa 2023-04 CU,
    # 23H2+: ms-settings:defaultapps?registeredAppMachine=<ime iz HKLM\Software\RegisteredApplications>.
    Invoke-Step -Name 'Chrome default za ovaj nalog (Settings)' -Action {
        if (-not (Get-ChromeExe)) {
            Write-Log -Message 'Chrome nije instaliran - Settings se ne otvara (nije greska)'
            return
        }
        $current = Get-UserChoiceProgId -Identifier 'http'
        if ($current -eq $BrowserProgId) {
            Write-Log -Message "Nalog $env:USERNAME vec ima Chrome kao default (http = $current)"
            return
        }
        $registered = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\RegisteredApplications' -Name $BrowserAppName -ErrorAction SilentlyContinue
        if (-not $registered) {
            Write-Log -Level WARN -Message "Chrome nije u HKLM\SOFTWARE\RegisteredApplications ('$BrowserAppName') - Settings se ne otvara, rucno (izvestaj)"
            return
        }
        $uri = 'ms-settings:defaultapps?registeredAppMachine=' + [System.Uri]::EscapeDataString($BrowserAppName)
        Invoke-Change -Description "Otvaram Settings za Chrome default ($uri) - nalog $env:USERNAME, http = $current" -Action {
            # Samo pomoc tehnicaru - ako ne uspe, WARN (ne greska sekcije: izvestaj ionako ima rucni korak)
            try {
                Start-Process -FilePath $uri -ErrorAction Stop
            }
            catch {
                Write-Log -Level WARN -Message "Settings nije otvoren: $($_.Exception.Message) - Chrome default rucno (izvestaj)"
            }
        }
    }
}

# Redosled izvrsavanja. Kljucevi moraju da se poklapaju sa [ValidateSet] u param() bloku.
$SectionMap = [ordered]@{
    Region  = { Invoke-RegionSection }
    Network = { Invoke-NetworkSection }
    Apps    = { Invoke-AppsSection }
    Browser = { Invoke-BrowserSection }
    Drivers = { Invoke-DriversSection }
    Report  = { Invoke-ReportSection }
}

# ============================================================================
#  GLAVNI TOK
# ============================================================================

# 1. Admin prava: ako ih nema - nova kopija kao admin, a ova se zavrsava sa njenim exit code-om
if (-not (Test-IsAdmin)) {
    exit (Invoke-Elevated)
}

# 2. Folder za log - bez njega nema logovanja, pa je greska ovde kraj
try {
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "Ne mogu da napravim folder za log ($LogDir): $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

# 3. Transcript - snima sve sto se pojavi na ekranu
try {
    Start-Transcript -Path $TranscriptFile -Append -ErrorAction Stop | Out-Null
    $script:TranscriptOn = $true
}
catch {
    Write-Log -Level WARN -Message "Transcript nije pokrenut: $($_.Exception.Message)"
}

try {
    Write-Log -Message '===== Setup.ps1 START ====='
    Write-Log -Message "Racunar: $env:COMPUTERNAME | Korisnik: $env:USERNAME | PowerShell: $($PSVersionTable.PSVersion)"
    Write-Log -Message "Folder skripte: $PSScriptRoot"
    Write-Log -Message "Vremenska zona: $(Get-TimeInfo)"
    if ($DryRun) {
        Write-Log -Level DRYRUN -Message 'Rezim: DRYRUN - nista se ne menja, state fajl se ne upisuje'
    }
    if ($Section) {
        Write-Log -Message "Trazene sekcije: $($Section -join ', ')"
    }

    # 4. Lock
    if (-not (Lock-Setup)) {
        $script:ExitCode = 2
    }
    else {
        # 5. State fajl; FirstStart se upisuje odmah (potreban za Event Viewer i posle restarta)
        $script:State = Get-SetupState
        Save-SetupState

        # 6. Nastavak posle restarta: task i Resume.ps1 se brisu ODMAH (pad u nastavku ne pravi petlju).
        # Ako opet treba restart, Invoke-RestartPlan ih pravi ponovo.
        $rebootCount = [int](Get-StateValue -Name 'RebootCount')
        if ($rebootCount -gt 0) {
            Write-Log -Message "Nastavak posle restarta ($rebootCount/$MaxRestarts)"
        }
        if ($DryRun) {
            Write-Log -Level DRYRUN -Message "Task $ResumeTaskName postoji: $([bool](Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue))"
        }
        else {
            Unregister-ResumeTask
        }
        $pending = @(Get-PendingRebootSource)
        if ($pending.Count -gt 0) {
            Write-Log -Message "Windows vec ceka restart: $($pending -join ', ')"
        }
        Clear-AutoLogon
        Enable-RestartGuard

        # 7. Sekcije redom (bez izvestaja); posle sekcije koja trazi restart ostale cekaju sledece pokretanje
        foreach ($name in @($SectionMap.Keys | Where-Object { $_ -ne 'Report' })) {
            if ($script:RestartNeeded) {
                Write-Log -SectionName $name -Message 'Preskacem: ceka restart (nastavak posle logovanja)'
                $script:Results.Add([pscustomobject]@{ Section = $name; Status = 'Waiting'; Seconds = 0 })
                continue
            }
            Invoke-Section -Name $name -Action $SectionMap[$name]
        }

        # 8. Restart (ako treba) ili kraj: brojac restarta se nulira kad pokretanje prodje bez restarta.
        # Izvestaj tek POSLE ciscenja, da pokaze i ono sto ciscenje nije uspelo da vrati.
        if ($script:RestartNeeded) {
            Invoke-RestartPlan
            $script:Results.Add([pscustomobject]@{ Section = 'Report'; Status = 'Waiting'; Seconds = 0 })
        }
        else {
            if ($rebootCount -gt 0) {
                Save-StateValue -Name 'RebootCount' -Value $null
            }
            # Lozinka naloga admin: samo na kraju CELOG Setup-a (sa -Section bi se trazila nova posle svakog testa)
            if ($Section) {
                Write-Log -Message "Lozinka naloga ${AdminAccountName}: preskacem (-Section) - podesava se samo na kraju celog Setup-a"
            }
            else {
                Invoke-Step -Name 'Lozinka naloga admin (nova pri sledecem logovanju)' -Action { Set-AdminPasswordChange }
            }
            Invoke-FinalCleanup
            Invoke-Section -Name 'Report' -Action $SectionMap['Report']
        }
        if ($script:Errors.Count -gt 0) {
            $script:ExitCode = 1
        }
    }
}
catch {
    # Greska u samom temelju (van sekcija) - i nju belezimo
    Add-ErrorRecord -ErrorRecord $_ -SectionName 'Main'
    $script:ExitCode = 1
}
finally {
    Complete-Setup
}

# Restart tek posle Complete-Setup: log je zatvoren i kopiran na fles, zastita vracena
if ($script:RestartPlanned) {
    Invoke-PlannedRestart
}

exit $script:ExitCode
