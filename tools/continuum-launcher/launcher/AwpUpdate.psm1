Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$assetName = 'awp-standalone-update.zip'
$repository = 'noahcabral/stalker-continuum'
$versionFile = '.awp-version'
$verificationFile = '.awp-update-files.json'
Import-Module (Join-Path $PSScriptRoot 'AwpVersionCheck.psm1')

function Find-AwpRelease([object[]]$Releases, [version]$CurrentVersion) {
    $candidates = foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease) { continue }
        if ($release.tag_name -notmatch '^awp-standalone-v(\d+\.\d+\.\d+)$') { continue }
        $version = [version]$Matches[1]
        if ($version -le $CurrentVersion) { continue }
        $asset = @($release.assets | Where-Object name -eq $assetName)
        if ($asset.Count -ne 1) { continue }
        $url = "https://github.com/$repository/releases/download/$($release.tag_name)/$assetName"
        if ($asset[0].browser_download_url -cne $url -or $asset[0].digest -notmatch '^sha256:([0-9a-f]{64})$') {
            throw "The update asset for $($release.tag_name) has invalid download metadata."
        }
        [pscustomobject]@{ Version=$version; Url=$url; Hash=$Matches[1] }
    }
    $candidates | Sort-Object Version -Descending | Select-Object -First 1
}

function Get-AwpVersion([string]$Root) {
    $path = Resolve-AwpTarget $Root $versionFile -VersionMarker
    if (Test-Path -LiteralPath $path -PathType Leaf) { return [version]([IO.File]::ReadAllText($path).Trim()) }
    [version]'0.0.0'
}

function Resolve-AwpTarget([string]$Root, [string]$RelativePath, [switch]$VersionMarker) {
    if (!($VersionMarker -and ($RelativePath -ceq $versionFile -or $RelativePath -ceq $verificationFile)) -and
        $RelativePath -notmatch '^(bin/|gamedata/|database/patch/)') { throw "Unsupported update path: $RelativePath" }
    $target = $Root
    foreach ($part in $RelativePath.Split('/')) {
        if (!$part -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $part -match '[. ]$' -or $part -match '^(CON|PRN|AUX|NUL|(?:COM|LPT)[0-9\u00b9\u00b2\u00b3])(?:\.|$)') {
            throw "Invalid update path: $RelativePath"
        }
        $target = Join-Path $target $part
        if (Test-Path -LiteralPath $target) {
            $item = Get-Item -LiteralPath $target -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Update path contains a link: $target" }
        }
    }
    return $target
}

function Clear-AwpTransaction([string]$Root) {
    $transaction = Join-Path $Root '.awp-update'
    if (!(Test-Path -LiteralPath $transaction)) { return }
    $item = Get-Item -LiteralPath $transaction -Force
    if ($item.FullName -ne $transaction -or !$item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The update staging directory is invalid.'
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

function Restore-AwpTransaction([string]$Root) {
    $transaction = Join-Path $Root '.awp-update'
    if (!(Test-Path -LiteralPath $transaction)) { return }
    $item = Get-Item -LiteralPath $transaction -Force
    if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The update staging directory is invalid.'
    }
    $journal = Join-Path $transaction 'journal.json'
    if ((Test-Path -LiteralPath $journal -PathType Leaf) -and
        !(Test-Path -LiteralPath (Join-Path $transaction 'committed') -PathType Leaf)) {
        $entries = @((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).files)
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $entry = $entries[$i]
            $target = Resolve-AwpTarget $Root $entry.path -VersionMarker
            $backup = Join-Path $transaction "backup\$i"
            $staged = Join-Path $transaction "prepared\$i"
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    [IO.File]::Replace($backup, $target, (Join-Path $transaction "backup\discard-$i"))
                }
                else { [IO.File]::Move($backup, $target) }
            }
            elseif (!$entry.existed -and !(Test-Path -LiteralPath $staged) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                [IO.File]::Delete($target)
            }
        }
    }
    Clear-AwpTransaction $Root
}

function Install-AwpArchive(
    [string]$Root, [string]$Archive, [version]$Version, [string]$Hash, [string]$BaselineSha256
) {
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $Hash) {
        throw 'The downloaded update did not match the GitHub SHA-256 digest.'
    }
    $transaction = Join-Path $Root '.awp-update'
    if (Test-Path -LiteralPath $transaction) { throw 'An earlier update needs recovery.' }
    New-Item -ItemType Directory -Path $transaction | Out-Null
    try {
        $prepared = Join-Path $transaction 'prepared'
        $backup = Join-Path $transaction 'backup'
        [void][IO.Directory]::CreateDirectory($prepared)
        [void][IO.Directory]::CreateDirectory($backup)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $manifest = $zip.GetEntry('manifest.json')
            if ($null -eq $manifest -or $manifest.Length -gt 2MB) { throw 'Invalid AWP update manifest.' }
            $reader = [IO.StreamReader]::new($manifest.Open())
            try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($metadata.format -cne 'awp-standalone-update-1' -or [version]$metadata.version -ne $Version) {
                throw 'The update manifest does not match the selected release.'
            }
            $current = Get-AwpVersion $Root
            if ($current -lt [version]$metadata.minimumVersion -or $Version -le $current) {
                throw 'This update is incompatible with the installed version.'
            }
            $files = @($metadata.files)
            if (!$files.Count -or $zip.Entries.Count -ne $files.Count + 1) { throw 'Invalid update file inventory.' }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $journal = @(for ($i = 0; $i -lt $files.Count; $i++) {
                $file = $files[$i]
                $target = Resolve-AwpTarget $Root $file.path
                if (!$seen.Add($file.path) -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or
                    (Test-Path -LiteralPath $target -PathType Container)) { throw "Invalid update file: $($file.path)" }
                $member = $zip.GetEntry($file.path)
                if ($null -eq $member) { throw "Missing update file: $($file.path)" }
                $staged = Join-Path $prepared $i
                [IO.Compression.ZipFileExtensions]::ExtractToFile($member, $staged)
                if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $file.sha256) {
                    throw "Invalid SHA-256 for $($file.path)"
                }
                @{ path=$file.path; existed=[IO.File]::Exists($target) }
            })
        }
        finally { $zip.Dispose() }

        if ($BaselineSha256) {
            $verificationPath = Resolve-AwpTarget $Root $verificationFile -VersionMarker
            $verification = New-AwpUpdatedFileReceipt $verificationPath $current $Version $BaselineSha256 $files
            if ($verification) {
                [IO.File]::WriteAllText((Join-Path $prepared $journal.Count), $verification)
                $journal += @{ path=$verificationFile; existed=[IO.File]::Exists($verificationPath) }
            }
        }
        $versionPath = Join-Path $Root $versionFile
        [IO.File]::WriteAllText((Join-Path $prepared $journal.Count), $Version.ToString())
        $journal += @{ path=$versionFile; existed=[IO.File]::Exists($versionPath) }
        $journalPath = Join-Path $transaction 'journal.json'
        $journalTemporary = "$journalPath.tmp"
        @{ files=$journal } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $journalTemporary -Encoding UTF8
        [IO.File]::Move($journalTemporary, $journalPath)

        for ($i = 0; $i -lt $journal.Count; $i++) {
            $entry = $journal[$i]
            $target = Resolve-AwpTarget $Root $entry.path -VersionMarker
            $staged = Join-Path $prepared $i
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            if ($entry.existed) { [IO.File]::Replace($staged, $target, (Join-Path $backup $i)) }
            else { [IO.File]::Move($staged, $target) }
        }
        [IO.File]::WriteAllText((Join-Path $transaction 'committed'), $Version.ToString())
        Clear-AwpTransaction $Root
    }
    catch {
        Restore-AwpTransaction $Root
        throw
    }
}

Export-ModuleMember -Function Find-AwpRelease, Get-AwpVersion, Install-AwpArchive, Restore-AwpTransaction
