param(
    [Parameter(Mandatory)][ValidateSet('Scan','Install','Repair','CheckUpdate','Update','Recover','RecoverRepair','VerifyFiles','CheckVersions','UpdateLauncher')][string]$Action,
    [AllowEmptyString()][string]$InstallRoot = '',
    [ValidatePattern('^(|[a-f0-9]{64})$')][string]$RepairApproval = '',
    [string]$LauncherUpdateRequest = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$attempt = [Diagnostics.Stopwatch]::StartNew()
$lastReport = -1000L

function Write-Receipt([hashtable]$Message) {
    [Console]::WriteLine(($Message | ConvertTo-Json -Compress -Depth 4))
}

function Report-Progress([string]$Message, [int]$Percent) {
    if ($attempt.ElapsedMilliseconds - $script:lastReport -lt 240 -and $Percent -lt 93) { return }
    $script:lastReport = $attempt.ElapsedMilliseconds
    Write-Receipt @{ Kind='Progress'; Message=$Message; Percent=$Percent }
}

function Get-UpdateChoice([object[]]$Releases, [version]$Installed, [scriptblock]$ReadManifest) {
    $known = foreach ($entry in $Releases) {
        $match = Find-AwpRelease @($entry) $Installed
        if (!$match) { continue }
        $asset = $entry.assets | Where-Object name -eq 'awp-standalone-update.zip'
        if ([long]$asset.size -le 0) { continue }
        [pscustomobject]@{ Version=$match.Version; Url=$match.Url; Hash=$match.Hash; Size=[long]$asset.size }
    }
    foreach ($pick in ($known | Sort-Object Version -Descending)) {
        try {
            $manifest = & $ReadManifest $pick.Url $pick.Size | ConvertFrom-Json
            if ($manifest.format -ceq 'awp-standalone-update-1' -and [version]$manifest.version -eq $pick.Version -and
                $Installed -ge [version]$manifest.minimumVersion -and @($manifest.files).Count -gt 0) { return $pick }
        } catch { }
    }
    return $null
}

function Get-AwpPublicReleases {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent'='AWP-Standalone-Launcher'; 'Accept'='application/vnd.github+json' }
    $releases = Invoke-RestMethod 'https://api.github.com/repos/noahcabral/stalker-continuum/releases?per_page=100' -Headers $headers -TimeoutSec 20
    foreach ($release in $releases) { $release }
}

function Get-AwpTrackedGameVersion([string]$State, [version]$InstalledVersion) {
    if ($State -eq 'Absent' -or !$InstalledVersion) { return }
    foreach ($marker in '.awp-version',[AwpInstall.Baseline]::Marker) {
        if ([AwpInstall.Baseline]::PlainFile([AwpInstall.Baseline]::Destination($root, $marker))) {
            return $InstalledVersion.ToString()
        }
    }
}

function Prepare-AwpLauncherUpdate {
    $bundle = Split-Path -Parent $PSScriptRoot
    $request = Join-Path $bundle 'launcher-update.request'
    if ($LauncherUpdateRequest -cne $request -or [IO.File]::Exists($request)) {
        throw 'Open the launcher executable to update it.'
    }
    $current = Read-AwpLauncherVersion $PSScriptRoot
    $available = Find-AwpLauncherRelease @(Get-AwpPublicReleases) -Details
    if (!$available -or $available.Version -le $current) { throw 'The launcher is up to date.' }
    if ($available.Size -gt 64MB) { throw 'The launcher download is unexpectedly large.' }
    $candidate = Join-Path $bundle 'next-launcher.exe'
    try {
        Report-Progress "Downloading launcher $($available.Version)..." 0
        $asset = [AwpInstall.Part]::new()
        $asset.Url, $asset.Size = $available.Url, $available.Size
        $inputStream = [AwpInstall.Network]::OpenAsset($asset)
        try {
            $output = [IO.File]::Open($candidate, 'CreateNew', 'Write', 'None')
            try {
                $buffer = [byte[]]::new(65536)
                while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -ne 0) {
                    if ($output.Length + $read -gt $available.Size) { throw 'The launcher download exceeded its expected size.' }
                    $output.Write($buffer, 0, $read)
                }
                if ($output.Length -ne $available.Size) { throw 'The launcher download ended early.' }
            } finally { $output.Dispose() }
        } finally { $inputStream.Dispose() }
        if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $available.Hash -or
            [Reflection.AssemblyName]::GetAssemblyName($candidate).Version.ToString(3) -cne $available.Version.ToString()) {
            throw 'The downloaded launcher did not match the published version and checksum.'
        }
        Report-Progress 'Checking the updated launcher...' 95
        $probe = Start-Process -FilePath $candidate -ArgumentList '--verify-layout' -WindowStyle Hidden -PassThru
        try {
            if (!$probe.WaitForExit(20000)) { $probe.Kill(); throw 'The new launcher did not finish its startup check.' }
            if ($probe.ExitCode -ne 0) { throw 'The new launcher failed its startup check.' }
        } finally { $probe.Dispose() }
        [IO.File]::WriteAllLines($request, @($available.Version.ToString(),$available.Hash))
        Write-Receipt @{ Kind='Result'; Message="Restarting the launcher at $($available.Version)." }
    } catch {
        if ([IO.File]::Exists($candidate)) { [IO.File]::Delete($candidate) }
        throw
    }
}

function Report-Versions([string]$State, [string]$GameVersion, [version]$UpdateBase) {
    $current = Read-AwpLauncherVersion $PSScriptRoot
    $message = ''
    $latest = $null
    $available = $null
    try {
        $releases = @(Get-AwpPublicReleases)
        $latest = Find-AwpLauncherRelease $releases
        if ($State -in 'Ready','Broken') {
            $available = Get-UpdateChoice $releases $UpdateBase { param($address,$size) [AwpInstall.Network]::UpdateManifest($address,$size) }
        }
    } catch { $message = 'Online version check unavailable.' }
    Write-Receipt @{
        Kind='Result'; State=$State; Message=$message; GameVersion=$GameVersion
        LauncherVersion=$current.ToString()
        LatestLauncherVersion=if ($latest) { $latest.ToString() } else { $null }
        LauncherUpdate=if ($latest -and $latest -gt $current) { $latest.ToString() } else { $null }
        Update=if ($available) { $available.Version.ToString() } else { $null }
    }
}

function Test-GameStopped {
    $isRunning = Get-Process -Name xrEngine -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $client }
    if ($isRunning) { throw 'Close the standalone before changing its files.' }
}

function Report-State([string]$Message) {
    $current = [AwpInstall.Baseline]::State($root, $inventory)
    $damage = if ($current -eq 'Broken') { [AwpInstall.Baseline]::CriticalDamage($root, $inventory) }
    [string]$gameVersion = if ($current -ne 'Absent') {
        try { Get-AwpTrackedGameVersion $current (Get-AwpVersion $root) } catch { }
    }
    Write-Receipt @{
        Kind='Result'; State=$current; Message=$Message; GameVersion=$gameVersion
        Damaged=@(if ($damage) { $damage.Keys | Sort-Object })
        RepairApproval=if ($damage) { [AwpInstall.Baseline]::RepairApproval($root, $damage) } else { '' }
    }
}

$updateLock = $null
$download = $null
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'AwpInstallCore.dll')
    Import-Module (Join-Path $PSScriptRoot 'AwpVersionCheck.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'AwpUpdate.psm1') -Force
    if ($Action -eq 'UpdateLauncher') { Prepare-AwpLauncherUpdate; return }
    if ($Action -eq 'CheckVersions' -and !$InstallRoot) { Report-Versions 'Absent' '' $null; return }
    $root = [AwpInstall.Baseline]::Root($InstallRoot)
    $client = Join-Path $root 'bin\xrEngine.exe'
    $bundled = Join-Path $PSScriptRoot 'baseline'
    $runtimeManifest = Join-Path $bundled 'BASELINE-runtime.sha256'
    $partManifest = Join-Path $bundled 'BASELINE-parts.sha256'
    $raw = Get-Content -Raw -LiteralPath (Join-Path $bundled 'baseline.json') | ConvertFrom-Json
    $release = [AwpInstall.Release]::new()
    $release.Tag = $raw.Tag
    $release.Assets = @(foreach ($entry in $raw.Assets) {
        $part = [AwpInstall.Part]::new()
        $part.Name, $part.Digest, $part.Url, $part.Size = $entry.Name, $entry.Digest, $entry.Url, $entry.Size
        $part
    })
    $releaseParts = [AwpInstall.Baseline]::ValidateRelease($release, $runtimeManifest, $partManifest)
    $inventory = [AwpInstall.Baseline]::ReadManifest($runtimeManifest, $true)
    $baselineSha = ($release.Assets | Where-Object Name -CEQ 'BASELINE-runtime.sha256').Digest.Substring(7)
    $state = [AwpInstall.Baseline]::State($root, $inventory)

    if ($Action -in 'CheckVersions','VerifyFiles') {
        $installed = if ($state -ne 'Absent') { Get-AwpVersion $root }
        $gameVersion = Get-AwpTrackedGameVersion $state $installed
        if ($Action -eq 'CheckVersions') { Report-Versions $state $gameVersion $installed; return }
        if ($state -notin 'Ready','Broken') { throw 'Select an installation with no pending recovery before verifying game files.' }
        $progress = [Action[string,int]]{ param($message,$percent) Report-Progress $message $percent }
        $verification = Test-AwpGameFiles $root $inventory $installed $baselineSha $progress
        $verification.Kind = 'Result'
        $verification.State = $state
        $verification.GameVersion = $gameVersion
        Write-Receipt $verification
        return
    }

    switch ($Action) {
        'Scan' { Report-State ''; return }
        'RecoverRepair' {
            if ($state -ne 'RepairRecovery') { throw 'No interrupted standalone repair was detected.' }
            $retained = [AwpInstall.Installer]::RecoverRepair($root, $inventory, [Action]{ Test-GameStopped })
            Report-State $(if ($retained) { "Interrupted repair completed. Originals: $retained" } else { 'Interrupted repair rolled back.' })
            return
        }
        { $_ -in 'Install','Repair' } {
            $stream = [Func[AwpInstall.Part,IO.Stream]]{ param($asset) [AwpInstall.Network]::OpenAsset($asset) }
            $progress = [Action[string,int]]{ param($message,$percent) Report-Progress $message $percent }
            $stopped = [Action]{ Test-GameStopped }
            $retained = [AwpInstall.Installer]::Apply($root, $inventory, $releaseParts, $stream, ($Action -eq 'Repair'), $progress, $stopped, $RepairApproval)
            Report-State $(if ($retained) { "Repair completed. Originals: $retained" } elseif ($Action -eq 'Repair') { 'Repair completed.' } else { 'Standalone installed.' })
            return
        }
    }

    if ($Action -eq 'Recover') {
        if ($state -ne 'Recovery') { throw 'No interrupted standalone update was detected.' }
        Test-GameStopped
        $lockPath = [AwpInstall.Baseline]::Destination($root, '.awp-update.lock')
        $updateLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        Restore-AwpTransaction $root
        Report-State 'Interrupted update recovered.'
        return
    }
    if ($state -ne 'Ready') { throw 'Repair the installation before checking for applicable updates.' }

    $updates = @(Get-AwpPublicReleases)
    $installed = Get-AwpVersion $root
    $available = Get-UpdateChoice @($updates) $installed { param($address,$size) [AwpInstall.Network]::UpdateManifest($address,$size) }
    if ($Action -eq 'CheckUpdate') {
        Write-Receipt @{ Kind='Result'; State='Ready'; Update=if ($available) { $available.Version.ToString() } else { $null } }
        return
    }
    if (!$available) { throw 'No verified update applies to this installation.' }
    Test-GameStopped
    $lockPath = [AwpInstall.Baseline]::Destination($root, '.awp-update.lock')
    $updateLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    if ([AwpInstall.Baseline]::State($root, $inventory) -ne 'Ready' -or (Get-AwpVersion $root) -ne $installed) {
        throw 'The installation changed during the update check. Try again.'
    }
    $download = [IO.Path]::GetTempFileName()
    $downloadPart = [AwpInstall.Part]::new()
    $downloadPart.Url, $downloadPart.Size = $available.Url, $available.Size
    $inputStream = [AwpInstall.Network]::OpenAsset($downloadPart)
    try {
        $destStream = [IO.File]::Open($download, 'Truncate', 'Write', 'None')
        try {
            $buffer = [byte[]]::new(1MB)
            $downloaded = 0L
            while (($chunk = $inputStream.Read($buffer,0,$buffer.Length)) -ne 0) {
                $downloaded += $chunk
                if ($downloaded -gt $available.Size) { throw 'The downloaded update exceeded its verified size.' }
                $destStream.Write($buffer,0,$chunk)
                Report-Progress "Downloading update $($available.Version)..." ([int](90.0 * $downloaded / $available.Size))
            }
            if ($downloaded -ne $available.Size) { throw 'The update download ended early.' }
        } finally { $destStream.Dispose() }
    } finally { $inputStream.Dispose() }
    Test-GameStopped
    Report-Progress 'Verifying and installing the update...' 95
    Install-AwpArchive $root $download $available.Version $available.Hash $baselineSha
    Report-State "Standalone updated to $($available.Version)."
} catch {
    $cause = $_.Exception
    while ($cause.InnerException) { $cause = $cause.InnerException }
    Write-Receipt @{ Kind='Error'; Message=$cause.Message }
    exit 1
} finally {
    if ($download -and [IO.File]::Exists($download)) { [IO.File]::Delete($download) }
    if ($updateLock) { $updateLock.Dispose() }
}
