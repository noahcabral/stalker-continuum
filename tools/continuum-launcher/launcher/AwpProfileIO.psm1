function Assert-AwpGameStopped([string]$ClientPath) {
    $client = [IO.Path]::GetFullPath($ClientPath)
    foreach ($process in @(Get-Process -Name xrEngine -ErrorAction SilentlyContinue)) {
        if (!$process.Path -or [string]::Equals($process.Path, $client, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Close the game before changing this profile.'
        }
    }
}

function Assert-AwpLocalPath([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        $item = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Profile path points through a link: $part"
        }
        $part = [IO.Path]::GetDirectoryName($part)
    }
}

function Open-AwpProfileLock([string]$Profile, [string]$ClientPath) {
    Assert-AwpGameStopped $ClientPath
    Assert-AwpLocalPath $Profile
    $lockPath = Join-Path $Profile '.awp-profile.lock'
    Assert-AwpLocalPath $lockPath
    try { [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another launcher is editing this profile, or the profile is read-only.' }
}

Export-ModuleMember -Function Assert-AwpGameStopped, Assert-AwpLocalPath, Open-AwpProfileLock
