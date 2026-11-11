#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallLocation,
    [string]$LocalIwpInstall,
    [uri]$RuntimeUrl,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RuntimeSha256
)

$ErrorActionPreference = 'Stop'
if (!$InstallLocation) { $InstallLocation = Read-Host 'New install folder (full path)' }
if (!$InstallLocation) { throw 'An install folder is required.' }
$destination = [IO.Path]::GetFullPath($InstallLocation)
if (Test-Path -LiteralPath $destination) { throw 'Choose a new folder. Existing installs are preserved.' }
if ($RuntimeUrl -and ($RuntimeUrl.Scheme -ne 'https' -or !$RuntimeSha256)) {
    throw 'A runtime download requires HTTPS and a SHA-256 hash.'
}
if (!$RuntimeUrl -and !$LocalIwpInstall) {
    $LocalIwpInstall = Read-Host 'Folder containing your locally supplied IWP x64 runtime (Enter for engine source only)'
}
if ($RuntimeUrl -and $LocalIwpInstall) { throw 'Specify either a runtime URL or a local runtime folder.' }
if ($LocalIwpInstall) {
    $LocalIwpInstall = (Resolve-Path -LiteralPath $LocalIwpInstall).Path
    $sourcePrefix = $LocalIwpInstall.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($destination.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Choose a destination outside the source runtime." }
    foreach ($file in 'bin/xrEngine.exe', 'database', 'gamedata', 'fsgame.ltx') {
        if (!(Test-Path -LiteralPath (Join-Path $LocalIwpInstall $file))) { throw "IWP runtime is missing $file." }
    }
}
$null = Get-Command git -ErrorAction Stop
$null = Get-Command gh -ErrorAction Stop
& gh auth status --hostname github.com
if ($LASTEXITCODE) { throw 'Sign in with gh auth login using an account with access to the private repository.' }

$staging = Join-Path (Split-Path -Parent $destination) ('.xr64-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $staging
try {
    & gh repo clone noahcabral/xr64multiplayer (Join-Path $staging 'engine-source') -- --branch iwp-compat --recurse-submodules
    if ($LASTEXITCODE) { throw 'The engine source download failed.' }
    $runtime = Join-Path $staging 'game'
    if ($RuntimeUrl) {
        $zip = Join-Path $staging 'runtime.zip'
        Invoke-WebRequest -Uri $RuntimeUrl -OutFile $zip -UseBasicParsing
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $RuntimeSha256) {
            throw 'The runtime archive did not match the expected SHA-256.'
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $runtime
        Remove-Item -LiteralPath $zip
    } elseif ($LocalIwpInstall) {
        $null = New-Item -ItemType Directory -Path $runtime
        foreach ($entry in 'bin', 'database', 'gamedata', 'fsgame.ltx') {
            Copy-Item -LiteralPath (Join-Path $LocalIwpInstall $entry) -Destination $runtime -Recurse
        }
    }
    if ($RuntimeUrl -or $LocalIwpInstall) {
        foreach ($file in 'bin/xrEngine.exe', 'database', 'gamedata', 'fsgame.ltx') {
            if (!(Test-Path -LiteralPath (Join-Path $runtime $file))) { throw "Installed runtime is missing $file." }
        }
    }
    Move-Item -LiteralPath $staging -Destination $destination
    Write-Host "Installed to $destination"
} catch {
    Write-Warning "Installation failed. Partial files are at $staging."
    throw
}
