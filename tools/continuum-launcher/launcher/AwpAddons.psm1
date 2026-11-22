function Test-AwpPack([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = [IO.BinaryReader]::new($stream)
        while (($stream.Length - $stream.Position) -ge 8) {
            $kind = $reader.ReadUInt32()
            $size = $reader.ReadUInt32()
            if ($size -gt ($stream.Length - $stream.Position)) { return $false }
            # X-Ray chunk 1 is the member table, optionally compressed.
            if (($kind -band [uint32]2147483647) -eq 1 -and $size -gt 0) { return $true }
            $stream.Position += $size
        }
        return $false
    }
    finally { $stream.Dispose() }
}

function Test-AwpAddonProof([string]$InstallRoot, $Proof) {
    if ($Proof.path -isnot [string]) { return $false }
    $relative = $Proof.path.Replace('\', '/')
    $packed = $relative -match '^database/(?:config|maps|patch|resource|sound)/[^/]+\.db[0-9]*$'
    if (!$packed -and $relative -notmatch '^gamedata/.+') { return $false }
    if ($relative -match '^gamedata/configs/xr64_addons/') { return $false }
    if ($relative -match '(^|/)\.{1,2}(?:/|$)|[:*?"<>|]|//') { return $false }

    # These paths are evidence for this installation. Skip links and junctions.
    $path = $InstallRoot
    foreach ($part in $relative.Split('/')) {
        if (!$part -or $part -ne $part.TrimEnd(' ', '.')) { return $false }
        $path = Join-Path $path $part
        $entry = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (!$entry -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    }
    if ($entry.PSIsContainer -or $entry.Length -eq 0) { return $false }

    if ($Proof.PSObject.Properties.Name -contains 'length') {
        if (($Proof.length -isnot [int] -and $Proof.length -isnot [long]) -or $Proof.length -ne $entry.Length) {
            return $false
        }
    }
    if ($Proof.PSObject.Properties.Name -contains 'contains') {
        if ($packed -or $entry.Length -gt 4194304 -or $Proof.contains -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Proof.contains)) { return $false }
        if ([IO.File]::ReadAllText($path).IndexOf($Proof.contains, [StringComparison]::Ordinal) -lt 0) {
            return $false
        }
    }
    if ($Proof.PSObject.Properties.Name -contains 'sha256') {
        if ($Proof.sha256 -isnot [string] -or $Proof.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $Proof.sha256) { return $false }
    }
    return !$packed -or (Test-AwpPack $path)
}

function Get-AwpAddons {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $declarations = @(
        (Join-Path $InstallRoot 'gamedata\configs\xr64_addons'),
        (Join-Path $PSScriptRoot 'baseline-addon-declarations')
    )
    $found = @{}
    $records = foreach ($directory in $declarations) {
        Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
    }
    foreach ($file in $records) {
        try {
            if ($file.Length -gt 65536 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ($record.schema -ne 1 -or $record.id -isnot [string] -or $record.id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or
                $record.name -isnot [string] -or [string]::IsNullOrWhiteSpace($record.name) -or
                $record.proof -isnot [array] -or $record.proof.Count -eq 0 -or $found.ContainsKey($record.id)) { continue }
            $proven = $true
            foreach ($proof in $record.proof) {
                if (!(Test-AwpAddonProof $InstallRoot $proof)) { $proven = $false; break }
            }
            if (!$proven) { continue }

            $name = $record.name.Trim()
            $version = if ($record.version -is [string] -and ![string]::IsNullOrWhiteSpace($record.version)) {
                "Version $($record.version.Trim())"
            } else { '' }
            $found[$record.id] = [pscustomobject]@{
                Id = $record.id
                Name = $name
                Version = $version
                AccessibleName = if ($version) { "$name, $version" } else { $name }
            }
        }
        catch { Write-Verbose "Skipped $($file.Name): $($_.Exception.Message)" }
    }
    $found.Values | Sort-Object Name, Id
}

Export-ModuleMember -Function Get-AwpAddons
