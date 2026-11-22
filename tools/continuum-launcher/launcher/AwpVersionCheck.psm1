Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-AwpLauncherVersion([string]$LauncherFolder) {
    $path = Join-Path $LauncherFolder 'version.json'
    if (![IO.File]::Exists($path) -or [IO.FileInfo]::new($path).Length -gt 4096) {
        throw 'Launcher version metadata is missing.'
    }
    $record = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($record.version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Launcher version metadata is invalid.' }
    return [version]$record.version
}

function Find-AwpLauncherRelease([object[]]$Releases, [switch]$Details) {
    $assetName = 'STALKER-Continuum-Launcher.exe'
    $base = 'https://github.com/noahcabral/stalker-continuum/releases/download'
    $valid = foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease -or $release.tag_name -cnotmatch '^continuum-launcher-v(\d+\.\d+\.\d+)$') { continue }
        $version = $null
        if (![version]::TryParse($Matches[1], [ref]$version)) { continue }
        $assets = @($release.assets | Where-Object name -CEQ $assetName)
        if ($assets.Count -ne 1) { continue }
        $asset = $assets[0]
        if ($asset.browser_download_url -cne "$base/$($release.tag_name)/$assetName" -or
            $asset.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or [long]$asset.size -le 0) { continue }
        [pscustomobject]@{ Version=$version; Url=$asset.browser_download_url; Hash=$asset.digest.Substring(7); Size=[long]$asset.size }
    }
    $selected = $valid | Sort-Object Version -Descending | Select-Object -First 1
    if ($selected) {
        if ($Details) { $selected } else { $selected.Version }
    }
}

function Test-AwpRuntimeReceiptPath([string]$Path) {
    $Path -match '^(?:bin/|gamedata/|database/patch/)'
}

function Get-AwpUpdatedFileHashes([string]$ReceiptPath, [version]$Version, [string]$BaselineSha256) {
    $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Version -eq [version]'0.0.0') { return $hashes }
    if (![IO.File]::Exists($ReceiptPath) -or [IO.FileInfo]::new($ReceiptPath).Length -gt 8MB) { return $null }
    try {
        $receipt = [IO.File]::ReadAllText($ReceiptPath) | ConvertFrom-Json
        if ($receipt.format -cne 'awp-installed-files-1' -or
            $receipt.version -cne $Version.ToString() -or $receipt.baselineSha256 -cne $BaselineSha256) {
            return $null
        }
        foreach ($row in $receipt.files) {
            if (!(Test-AwpRuntimeReceiptPath $row.path) -or $row.sha256 -cnotmatch '^[a-f0-9]{64}$') { return $null }
            [AwpInstall.Baseline]::ValidateRelative($row.path.ToLowerInvariant(), $false)
            $hashes.Add($row.path, $row.sha256)
        }
        return $hashes
    } catch { return $null }
}

function New-AwpUpdatedFileReceipt(
    [string]$ReceiptPath, [version]$Current, [version]$Version, [string]$BaselineSha256, [object[]]$UpdatedFiles
) {
    $hashes = Get-AwpUpdatedFileHashes $ReceiptPath $Current $BaselineSha256
    if ($null -eq $hashes) { return $null }
    foreach ($row in $UpdatedFiles) { $hashes[$row.path] = $row.sha256.ToLowerInvariant() }
    @{
        format = 'awp-installed-files-1'
        version = $Version.ToString()
        baselineSha256 = $BaselineSha256
        files = @($hashes.GetEnumerator() | Sort-Object Key | ForEach-Object { @{ path=$_.Key; sha256=$_.Value } })
    } | ConvertTo-Json -Depth 4 -Compress
}

function Test-AwpGameFiles(
    [string]$Root, [Collections.Generic.Dictionary[string,string]]$BaselineFiles, [version]$Version,
    [string]$BaselineSha256, [Action[string,int]]$ReportProgress
) {
    $overlayPath = [AwpInstall.Baseline]::Destination($Root, '.awp-update-files.json')
    $lockPath = [AwpInstall.Baseline]::Destination($Root, '.awp-update.lock')
    $lease = $null
    try {
        if ([IO.File]::Exists($lockPath)) {
            $lease = [IO.File]::Open($lockPath, 'Open', 'Read', 'Read')
        }
        if ([IO.Directory]::Exists([AwpInstall.Baseline]::Destination($Root, '.awp-update'))) {
            throw 'Recover the interrupted update before verifying files.'
        }
        $overlay = Get-AwpUpdatedFileHashes $overlayPath $Version $BaselineSha256
        if ($null -eq $overlay) {
            return @{ Available=$false; Message='No matching file inventory is available for this installed game version.' }
        }
        $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $BaselineFiles.GetEnumerator()) {
            if ($row.Key -eq 'fsgame.ltx' -or $row.Key -match '^(?:bin/|gamedata/|database/)') {
                $expected.Add($row.Key, $row.Value)
            }
        }
        foreach ($row in $overlay.GetEnumerator()) { $expected[$row.Key] = $row.Value }
        if (!$expected.Count) { throw 'The runtime file inventory is empty.' }

        $missing = [Collections.Generic.List[string]]::new()
        $changed = [Collections.Generic.List[string]]::new()
        $unreadable = [Collections.Generic.List[string]]::new()
        $done = 0
        foreach ($name in ($expected.Keys | Sort-Object)) {
            try {
                $target = [AwpInstall.Baseline]::Destination($Root, $name)
                $attributes = [AwpInstall.Baseline]::Attributes($target)
                if ($null -eq $attributes) { $missing.Add($name) }
                elseif (![AwpInstall.Baseline]::PlainFile($target)) { $changed.Add($name) }
                elseif (![AwpInstall.Baseline]::Matches($target, $expected[$name])) { $changed.Add($name) }
            } catch { $unreadable.Add($name) }
            $done++
            if ($ReportProgress -and ($done -eq $expected.Count -or $done % 32 -eq 0)) {
                $ReportProgress.Invoke("Checking game files ($done/$($expected.Count))...", [int](100 * $done / $expected.Count))
            }
        }
        if (!$lease -and [IO.File]::Exists($lockPath)) {
            throw 'An update or repair started while files were being checked. Run Verify files again.'
        }
        return @{
            Available=$true; Checked=$done; Missing=$missing.ToArray(); Changed=$changed.ToArray()
            Unreadable=$unreadable.ToArray(); Message="$done files checked. $($missing.Count) missing, $($changed.Count) changed, $($unreadable.Count) unreadable."
        }
    } finally {
        if ($lease) { $lease.Dispose() }
    }
}

Export-ModuleMember -Function Read-AwpLauncherVersion, Find-AwpLauncherRelease, New-AwpUpdatedFileReceipt, Test-AwpGameFiles
