Import-Module (Join-Path $PSScriptRoot 'AwpProfileIO.psm1')

$extensions = '.scop', '.scoc', '.dds'

function Get-AwpSaves([string]$SaveFolder) {
    Assert-AwpLocalPath $SaveFolder
    $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath $SaveFolder -File -ErrorAction SilentlyContinue)) {
        if ($file.Extension -notin $extensions -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if (!$groups.ContainsKey($file.BaseName)) { $groups[$file.BaseName] = [Collections.Generic.List[IO.FileInfo]]::new() }
        $groups[$file.BaseName].Add($file)
    }
    $result = foreach ($group in $groups.Values) {
        $files = @($group | Sort-Object Name)
        $signature = ($files | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join [char]10
        foreach ($primary in @($files | Where-Object Extension -eq '.scop')) {
            [pscustomobject]@{
                Name = $primary.BaseName
                FileName = $primary.Name
                Date = $primary.LastWriteTimeUtc
                DisplayDate = $primary.LastWriteTime.ToString('g')
                Files = $files
                Signature = $signature
            }
        }
    }
    $result | Sort-Object @{ Expression = 'Date'; Descending = $true }, Name
}

function Get-AwpQuarantineRoot([string]$SaveFolder) {
    Join-Path ([IO.Path]::GetDirectoryName($SaveFolder)) 'save-quarantine'
}

function Get-AwpReceipt([string]$Directory) {
    $file = Join-Path $Directory 'receipt.json'
    Assert-AwpLocalPath $file
    $receipt = [IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.schema -ne 1 -or $receipt.name -isnot [string] -or [string]::IsNullOrWhiteSpace($receipt.name) -or
        $receipt.files -isnot [array] -or $receipt.files.Count -notin 1, 2, 3) { throw 'Invalid save receipt.' }
    $types = @{}
    foreach ($part in $receipt.files) {
        if ($part.name -isnot [string] -or $part.name -cne [IO.Path]::GetFileName($part.name) -or
            $part.name -ne $part.name.TrimEnd(' ', '.') -or $part.name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            ![string]::Equals([IO.Path]::GetFileNameWithoutExtension($part.name), $receipt.name,
                [StringComparison]::OrdinalIgnoreCase) -or
            $part.sha256 -isnot [string] -or $part.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid save companion in receipt.' }
        $extension = [IO.Path]::GetExtension($part.name)
        if ($extension -notin $extensions -or $types.ContainsKey($extension)) { throw 'Ambiguous save companions in receipt.' }
        $types[$extension] = $true
    }
    if (!$types.ContainsKey('.scop')) { throw 'Save receipt is missing its .scop entry.' }
    $receipt
}

function Get-AwpRemovedSaves([string]$SaveFolder) {
    $root = Get-AwpQuarantineRoot $SaveFolder
    Assert-AwpLocalPath $root
    $rows = foreach ($folder in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if ($folder.Name -notmatch '^[a-f0-9]{32}\.(deleted|pending)$') { continue }
        try {
            $receipt = Get-AwpReceipt $folder.FullName
            $state = if ($folder.Extension -eq '.pending') { 'Interrupted operation' } else { 'Removed' }
            [pscustomobject]@{
                Id = $folder.Name
                Name = $receipt.name
                Date = $folder.LastWriteTime
                DisplayName = "$($receipt.name) ($state)"
            }
        }
        catch { Write-Verbose "Unreadable save receipt in $($folder.Name): $($_.Exception.Message)" }
    }
    $rows | Sort-Object Date -Descending
}

function Complete-AwpSaveRestore([string]$SaveFolder, [string]$Directory, [string]$ClientPath) {
    $receipt = Get-AwpReceipt $Directory
    $plans = foreach ($part in $receipt.files) {
        $source = Join-Path $Directory $part.name
        $destination = Join-Path $SaveFolder $part.name
        Assert-AwpLocalPath $source
        Assert-AwpLocalPath $destination
        $inQuarantine = [IO.File]::Exists($source)
        $inGame = [IO.File]::Exists($destination)
        if ($inQuarantine -eq $inGame) { throw "Cannot safely restore '$($part.name)'. Check for a missing file or name conflict." }
        $current = if ($inQuarantine) { $source } else { $destination }
        if ((Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash -ne $part.sha256) {
            throw "Save file '$($part.name)' changed since removal."
        }
        if ($inQuarantine) {
            [pscustomobject]@{ Source = $source; Destination = $destination; Primary = [IO.Path]::GetExtension($source) -eq '.scop' }
        }
    }

    foreach ($move in ($plans | Sort-Object Primary)) {
        Assert-AwpGameStopped $ClientPath
        [IO.File]::Move($move.Source, $move.Destination)
    }
    [IO.Directory]::Move($Directory, [IO.Path]::ChangeExtension($Directory, '.restored'))
}

function Move-AwpSaveToQuarantine([string]$SaveFolder, [string]$ClientPath, $Save) {
    $profile = [IO.Path]::GetDirectoryName($SaveFolder)
    $lock = Open-AwpProfileLock $profile $ClientPath
    try {
        $current = @(Get-AwpSaves $SaveFolder | Where-Object { $_.FileName -ceq $Save.FileName })
        if ($current.Count -ne 1 -or $current[0].Signature -cne $Save.Signature) {
            throw 'That save changed or disappeared. Refresh, then select it again.'
        }
        $bundle = $current[0]
        if (@($bundle.Files | Group-Object Extension | Where-Object Count -gt 1).Count) {
            throw 'This save has multiple files for one companion type.'
        }
        $root = Get-AwpQuarantineRoot $SaveFolder
        Assert-AwpLocalPath $root
        $pending = Join-Path $root ([guid]::NewGuid().ToString('n') + '.pending')
        $receipt = @{
            schema = 1
            name = $bundle.Name
            files = @($bundle.Files | ForEach-Object {
                Assert-AwpLocalPath $_.FullName
                @{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
            })
        }
        [void][IO.Directory]::CreateDirectory($pending)
        [IO.File]::WriteAllText((Join-Path $pending 'receipt.json'), ($receipt | ConvertTo-Json -Depth 4))
        try {
            foreach ($part in ($bundle.Files | Sort-Object { $_.Extension -ne '.scop' })) {
                Assert-AwpGameStopped $ClientPath
                [IO.File]::Move($part.FullName, (Join-Path $pending $part.Name))
            }
            [IO.Directory]::Move($pending, [IO.Path]::ChangeExtension($pending, '.deleted'))
        }
        catch {
            $failure = $_.Exception.Message
            try { Complete-AwpSaveRestore $SaveFolder $pending $ClientPath }
            catch { throw "Could not remove '$($bundle.Name)'. Its interrupted operation is available under Removed saves. $failure" }
            throw "The save was restored after removal failed. $failure"
        }
    }
    finally { $lock.Dispose() }
}

function Restore-AwpSave([string]$SaveFolder, [string]$ClientPath, [string]$Id) {
    if ($Id -notmatch '^[a-f0-9]{32}\.(deleted|pending)$') { throw 'Invalid save recovery ID.' }
    $lock = Open-AwpProfileLock ([IO.Path]::GetDirectoryName($SaveFolder)) $ClientPath
    try {
        $directory = Join-Path (Get-AwpQuarantineRoot $SaveFolder) $Id
        Assert-AwpLocalPath $SaveFolder
        $receipt = Get-AwpReceipt $directory
        if ([IO.Path]::GetExtension($Id) -eq '.deleted') {
            foreach ($part in $receipt.files) {
                if (Test-Path -LiteralPath (Join-Path $SaveFolder $part.name)) {
                    throw "A save file named '$($part.name)' already exists."
                }
            }
            $pending = [IO.Path]::ChangeExtension($directory, '.pending')
            [IO.Directory]::Move($directory, $pending)
            $directory = $pending
        }
        Complete-AwpSaveRestore $SaveFolder $directory $ClientPath
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-AwpSaves, Get-AwpRemovedSaves, Move-AwpSaveToQuarantine, Restore-AwpSave
