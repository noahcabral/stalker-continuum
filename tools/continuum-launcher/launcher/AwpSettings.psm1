Import-Module (Join-Path $PSScriptRoot 'AwpProfileIO.psm1')

$invariant = [Globalization.CultureInfo]::InvariantCulture
$definitions = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'AwpSettingsCatalog.psd1')).Settings
$settingsByKey = @{}
foreach ($entry in $definitions) { $settingsByKey.Add($entry.Key, $entry) }
$commandPattern = [regex]::new(
    '^(?<prefix>[ \t]*(?<key>[a-zA-Z0-9_]+)[ \t]+)(?<value>.*?)(?<suffix>[ \t]*(?:;.*|//.*)?)$')

function Get-AwpSettingDefinitions { $definitions }

function ConvertTo-AwpSettingValue([string]$Key, [string]$Text) {
    $text = $Text.Trim()
    $entry = $settingsByKey[$Key]
    if ($entry.Kind -eq 'Toggle' -or $Key -in 'rs_fullscreen', 'rs_refresh_60hz') {
        if ($text -in 'on', '1') { return 'on' }
        if ($text -in 'off', '0') { return 'off' }
    }
    elseif ($entry.Kind -eq 'Switch') {
        if ($text -in '0','1') { return $text }
    }
    elseif ($entry.Kind -eq 'Choice') {
        foreach ($choice in $entry.Choices) {
            if ($text -eq $choice[0]) { return $choice[0] }
        }
    }
    elseif ($entry.Kind -eq 'RuntimeChoice') {
        if ($text -match '^[^\x00-\x1f;]{1,200}$' -and !$text.Contains('//')) { return $text }
    }
    elseif ($entry.Kind -eq 'Resolution') {
        if (!$text) { return '' }
        if ($text -match '^(?<w>[1-9]\d{0,4})x(?<h>[1-9]\d{0,4})(?:\s+\((?<hz>\d{1,4})Hz\))?$') {
            $mode = "$($Matches.w)x$($Matches.h)"
            if ($Matches.hz) { $mode += " ($([int]$Matches.hz)Hz)" }
            return $mode
        }
    }
    elseif ($entry.Kind -in 'Integer', 'Number') {
        $number = 0.0
        $format = if ($entry.Kind -eq 'Integer') { 'Integer' } else { 'Float' }
        if ([double]::TryParse($text, [Globalization.NumberStyles]$format, $invariant, [ref]$number) -and
            $number -ge $entry.Min -and $number -le $entry.Max) {
            return $number.ToString('G', $invariant)
        }
    }
    return $null
}

function Get-AwpSettingsFingerprint([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToBase64String($algorithm.ComputeHash($Bytes)) }
    finally { $algorithm.Dispose() }
}

function ConvertFrom-AwpLogBytes([string]$Value) {
    $rawEncoding = [Text.Encoding]::GetEncoding(28591)
    $unicode = [Text.UTF8Encoding]::new($false, $true)
    try { $unicode.GetString($rawEncoding.GetBytes($Value)) }
    catch [Text.DecoderFallbackException] { $Value }
}

function Get-AwpRuntimeSettingChoices([string]$Profile) {
    $runtime = @{ renderer = @(); snd_device = @(); LastSoundDevice = $null }
    $directory = Join-Path $Profile 'logs'
    if (![IO.Directory]::Exists($directory)) { return $runtime }
    Assert-AwpLocalPath $directory
    $log = Get-ChildItem -LiteralPath $directory -File -Filter 'openxray*.log' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (!$log) { return $runtime }
    Assert-AwpLocalPath $log.FullName
    $rawEncoding = [Text.Encoding]::GetEncoding(28591)
    $remainingModes = 0
    $inAudioList = $false
    $stream = [IO.File]::Open($log.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream, $rawEncoding, $false)
    try {
        for ($index = 0; $index -lt 256 -and !$reader.EndOfStream; $index++) {
            $line = $reader.ReadLine()
            if ($index -eq 0) { $line = $line -replace '^\u00ef\u00bb\u00bf' }
            if ($line -match '^Available render modes\[(\d+)\]:\s*$') {
                $remainingModes = [int]$Matches[1]
                continue
            }
            if ($remainingModes) {
                $remainingModes--
                $mode = $line.Trim()
                foreach ($choice in $settingsByKey.renderer.Choices) {
                    if ($mode -ceq $choice[0] -and $mode -cnotin $runtime.renderer.Value) {
                        $runtime.renderer += [pscustomobject]@{ Value = $mode; Label = $choice[1] }
                    }
                }
            }
            if ($line -match '^SOUND: Selected device is (.+)$') {
                $runtime.LastSoundDevice = ConvertFrom-AwpLogBytes $Matches[1]
            }
            if ($line -match '^SOUND: OpenAL: All available devices:\s*$') {
                $inAudioList = $true
                continue
            }
            if ($inAudioList) {
                if ($line -notmatch '^\d+\. (.+), Spec Version \d+\.\d+.*$') {
                    $inAudioList = $false
                    continue
                }
                $device = ConvertTo-AwpSettingValue snd_device $Matches[1]
                if (!$device -or $device -cin $runtime.snd_device.Value) { continue }
                $runtime.snd_device += [pscustomobject]@{ Value = $device; Label = ConvertFrom-AwpLogBytes $device }
            }
        }
    }
    finally { $reader.Dispose() }
    $runtime
}

function Read-AwpSettingsBytes([byte[]]$Bytes) {
    # Console commands are ASCII. Latin-1 round trips every byte of the game's
    # normal profile, whether comments use UTF-8 or a legacy code page.
    $encoding = [Text.Encoding]::GetEncoding(28591)
    $bom = 0
    if ($Bytes.Length -ge 2) {
        if ($Bytes[0] -eq 255 -and $Bytes[1] -eq 254) { $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $bom = 2 }
        if ($Bytes[0] -eq 254 -and $Bytes[1] -eq 255) { $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $bom = 2 }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) { $bom = 3 }
    $text = $encoding.GetString($Bytes, $bom, $Bytes.Length - $bom)
    $preamble = [byte[]]::new($bom)
    [Array]::Copy($Bytes, $preamble, $bom)
    $parts = [regex]::Split($text, '(\r\n|\n|\r)')
    $values = @{}
    foreach ($entry in $definitions) { $values[$entry.Key] = $entry.Default }
    $positions = @{}
    $refresh = $null
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $match = $commandPattern.Match($parts[$i])
        if (!$match.Success) { continue }
        $key = $match.Groups['key'].Value
        if (!$values.ContainsKey($key) -and $key -notin 'rs_fullscreen','rs_refresh_60hz') { continue }
        $value = ConvertTo-AwpSettingValue $key $match.Groups['value'].Value
        if ($null -eq $value) { continue }
        if ($key -eq 'rs_fullscreen') {
            $values.vid_window_mode = if ($value -eq 'on') { 'st_opt_fullscreen' } else { 'st_opt_windowed_borderless' }
            $positions.Remove('vid_window_mode')
        }
        elseif ($key -eq 'rs_refresh_60hz') {
            $refresh = if ($value -eq 'on') { 60 } else { 0 }
            if ($values.vid_mode) { $values.vid_mode = ($values.vid_mode -replace ' \(\d+Hz\)$') + " (${refresh}Hz)" }
            $positions.Remove('vid_mode')
        }
        else {
            if ($key -eq 'vid_mode') {
                if ($value -match ' \((\d+)Hz\)$') { $refresh = [int]$Matches[1] }
                elseif ($null -ne $refresh) { $value += " (${refresh}Hz)" }
            }
            $values[$key] = $value
            $positions[$key] = $i
        }
    }
    [pscustomobject]@{
        Fingerprint = Get-AwpSettingsFingerprint $Bytes
        Values = $values
        Positions = $positions
        Parts = $parts
        Encoding = $encoding
        Preamble = $preamble
    }
}

function Get-AwpSettings([string]$SettingsPath) {
    Assert-AwpLocalPath $SettingsPath
    if (![IO.File]::Exists($SettingsPath)) { throw 'The game settings file could not be found.' }
    $snapshot = Read-AwpSettingsBytes ([IO.File]::ReadAllBytes($SettingsPath))
    $runtime = try { Get-AwpRuntimeSettingChoices ([IO.Path]::GetDirectoryName($SettingsPath)) }
               catch { @{ renderer = @(); snd_device = @(); LastSoundDevice = $null } }
    # Runtime choices are read as original bytes. Convert non-ASCII device names
    # to Unicode only for a profile that is stored as UTF-16.
    if ($snapshot.Encoding -is [Text.UnicodeEncoding]) {
        foreach ($choice in $runtime.snd_device) { $choice.Value = $choice.Label }
    }
    Add-Member -InputObject $snapshot -NotePropertyName RuntimeChoices -NotePropertyValue $runtime
    $snapshot
}

function Save-AwpSettings([string]$SettingsPath, [string]$ClientPath, $Snapshot, [hashtable]$Values) {
    $changes = [ordered]@{}
    foreach ($entry in $definitions) {
        $key = $entry.Key
        if (!$Values.ContainsKey($key)) { continue }
        $value = ConvertTo-AwpSettingValue $key $Values[$key]
        if ($null -eq $value -or (!$value -and $Snapshot.Values[$key])) {
            throw "Invalid value for $($entry.Label) ($key)."
        }
        if ($key -eq 'vid_mode' -and $value -and $value -notmatch 'Hz\)$' -and $Snapshot.Values[$key] -match ' \(\d+Hz\)$') {
            $value += $Matches[0]
        }
        if ($value -ceq $Snapshot.Values[$key]) { continue }
        if ($entry.Kind -eq 'RuntimeChoice' -and $value -cnotin $Snapshot.RuntimeChoices[$key].Value) {
            throw "Choose an available value for $($entry.Label)."
        }
        $changes[$key] = $value
    }
    $renderer = if ($changes.Contains('renderer')) { $changes.renderer } else { $Snapshot.Values.renderer }
    foreach ($key in $changes.Keys) {
        $entry = $settingsByKey[$key]
        if ($entry.Renderers -and $renderer -notin $entry.Renderers) {
            throw "$($entry.Label) is unavailable for the selected renderer."
        }
    }
    if ($renderer -eq 'renderer_rgl' -and $changes.r2_sun_quality -in 'st_opt_ultra','st_opt_extreme') {
        throw 'OpenGL supports Low, Medium, and High sun shadow quality.'
    }
    if ($changes.Contains('r2_ssao') -or $changes.Contains('r2_ssao_mode')) {
        $mode = if ($changes.Contains('r2_ssao_mode')) { $changes.r2_ssao_mode } else { $Snapshot.Values.r2_ssao_mode }
        $quality = if ($changes.Contains('r2_ssao')) { $changes.r2_ssao } else { $Snapshot.Values.r2_ssao }
        if ($changes.Contains('r2_ssao') -and $changes.Contains('r2_ssao_mode') -and
            (($mode -eq 'disabled') -xor ($quality -eq 'st_opt_off'))) {
            throw 'Choose compatible ambient occlusion settings. Select Off for both controls, or an enabled algorithm and quality.'
        }
        if ($mode -eq 'disabled' -or $quality -eq 'st_opt_off') {
            if ($changes.Contains('r2_ssao') -and $quality -ne 'st_opt_off') { $changes.r2_ssao_mode = 'default' }
            elseif ($changes.Contains('r2_ssao_mode') -and $mode -ne 'disabled') { $changes.r2_ssao = 'st_opt_low' }
            else {
                if ($mode -ne 'disabled') { $changes.r2_ssao_mode = 'disabled' }
                if ($quality -ne 'st_opt_off') { $changes.r2_ssao = 'st_opt_off' }
            }
        }
    }
    if (!$changes.Count) { return 0 }

    $folder = [IO.Path]::GetDirectoryName($SettingsPath)
    $lock = Open-AwpProfileLock $folder $ClientPath
    $temporary = Join-Path $folder ('.awp-settings-' + [guid]::NewGuid().ToString('n') + '.tmp')
    try {
        Assert-AwpLocalPath $SettingsPath
        $guard = [IO.File]::Open($SettingsPath, 'Open', 'Read', ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        try {
            $buffer = [IO.MemoryStream]::new()
            try { $guard.CopyTo($buffer); $current = Read-AwpSettingsBytes $buffer.ToArray() }
            finally { $buffer.Dispose() }
            if ($current.Fingerprint -cne $Snapshot.Fingerprint) { throw 'Settings changed on disk. Reload before applying your edits.' }

            $append = @()
            foreach ($key in $changes.Keys) {
                if ($current.Positions.ContainsKey($key)) {
                    $index = $current.Positions[$key]
                    $line = $commandPattern.Match($current.Parts[$index])
                    $current.Parts[$index] = $line.Groups['prefix'].Value + $changes[$key] + $line.Groups['suffix'].Value
                }
                else { $append += "$key $($changes[$key])" }
            }
            $text = $current.Parts -join ''
            if ($append.Count) {
                $end = if ($current.Parts.Count -gt 1) { $current.Parts[1] } else { [Environment]::NewLine }
                $finalNewline = $text -match '[\r\n]$'
                if ($text -and !$finalNewline) { $text += $end }
                $text += $append -join $end
                if ($finalNewline) { $text += $end }
            }
            [byte[]]$bytes = $current.Preamble + $current.Encoding.GetBytes($text)
            [IO.File]::WriteAllBytes($temporary, $bytes)
            Assert-AwpGameStopped $ClientPath
            [IO.File]::Replace($temporary, $SettingsPath, [NullString]::Value)
            return $changes.Count
        }
        finally { $guard.Dispose() }
    }
    finally {
        try { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        finally { $lock.Dispose() }
    }
}

Export-ModuleMember -Function Get-AwpSettingDefinitions, Get-AwpSettings, Save-AwpSettings, ConvertFrom-AwpLogBytes
