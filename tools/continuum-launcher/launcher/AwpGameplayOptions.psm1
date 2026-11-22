Import-Module (Join-Path $PSScriptRoot 'AwpProfileIO.psm1')

$invariant = [Globalization.CultureInfo]::InvariantCulture
$byteEncoding = [Text.Encoding]::GetEncoding(28591)
$populationChoices = @('0.25', '0.5', '0.75', '1')
$modOptions = @(
    @{ Key='enable_actor_hit'; Label='Hit screen effects'; Default='true' }
    @{ Key='enable_actor_bleeding'; Label='Bleeding screen effects'; Default='true' }
    @{ Key='enable_show_enemy_health'; Label='Show enemy health'; Default='true' }
    @{ Key='enable_scope_notify'; Label='Show scope control prompts'; Default='true' }
    @{ Key='enable_slot_hud'; Label='Show equipment slots and companions'; Default='true' }
    @{ Key='enable_outfit_portrait'; Label='Use outfit portraits'; Default='true' }
    @{ Key='enable_dynamic_news'; Label='Dynamic news'; Default='true' }
    @{ Key='enable_radio_mod'; Label='In-world radio music'; Default='true' }
    @{ Key='enable_heli_spawn'; Label='Spawn helicopters'; Default='true'; Help='Choose this before starting a new game.' }
    @{ Key='enable_heli_engine_sound'; Label='Helicopter engine sounds'; Default='true'; Help='Requires helicopter spawning.' }
    @{ Key='enable_release_dropped_items'; Label='Remove dropped items over time'; Default='true'; Help='Dropped items are eligible for removal after four in-game hours.' }
    @{ Key='enable_mechanic_feature'; Label='Repairs take time'; Default='false' }
    @{ Key='alife_mutant_pop'; Label='Mutant population'; Default='0.5'; Choices=$populationChoices; Labels=@('25%','50%','75%','100%'); Help='Existing squads can take time to reflect a population change.' }
    @{ Key='alife_stalker_pop'; Label='Stalker population'; Default='0.5'; Choices=$populationChoices; Labels=@('25%','50%','75%','100%'); Help='Existing squads can take time to reflect a population change.' }
    @{ Key='excl_dist'; Label='Minimum simulation spawn distance'; Default='50'; Choices=@('0','25','50','100'); Labels=@('0 m','25 m','50 m','100 m') }
    @{ Key='quicksave_cnt'; Label='Rotating quicksave slots'; Default='5'; Choices=@('1','5','10','20') }
)
$optionIndex = [Collections.Generic.Dictionary[string,hashtable]]::new([StringComparer]::Ordinal)
foreach ($option in $modOptions) { $optionIndex.Add($option.Key, $option) }

$iniLine = [regex]::new('^(?<prefix>[ \t]*(?<key>[a-zA-Z0-9_]+)[ \t]*=[ \t]*)(?<value>"[^"]*"|.*?)(?<suffix>[ \t]*(?:;.*|//.*)?)$')

function Get-AwpGameplayOptionDefinitions { $modOptions }

function Get-AwpGameplayOptionPath([string]$InstallRoot) {
    [IO.Path]::GetFullPath((Join-Path $InstallRoot 'gamedata\configs\axr_options.ltx'))
}

function Read-AwpGameplayOptionBytes([byte[]]$Bytes) {
    # X-Ray LTX is byte-oriented. Keep comments and code-page bytes verbatim.
    if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { throw 'Gameplay options require an X-Ray text file with an ASCII-compatible encoding.' }
    $text = $byteEncoding.GetString($Bytes)
    $parts = [regex]::Split($text, '(\r\n|\n|\r)')
    $header = $null
    $inOptions = $false
    $values = @{}
    $positions = @{}
    foreach ($option in $modOptions) { $values[$option.Key] = $option.Default }

    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $line = $parts[$i]
        if ($i -eq 0) { $line = $line -replace '^\u00ef\u00bb\u00bf' }
        if ($line -match '^[ \t]*#include\b') { throw 'The gameplay options file uses an include. Edit its options through the game.' }
        if ($line -match '^[ \t]*\[(?<section>[^\]]+)\](?<tail>.*)$') {
            $inOptions = $Matches.section -ieq 'mm_options'
            if ($inOptions) {
                if ($null -ne $header -or $Matches.tail -match '^[ \t]*:') {
                    throw 'The gameplay options section must occur once and have no parent sections.'
                }
                $header = $i
            }
            continue
        }
        if (!$inOptions) { continue }
        $match = $iniLine.Match($line)
        if (!$match.Success) {
            if ($line -cmatch '^[ \t]*([a-zA-Z0-9_]+)[ \t]*(?:;.*|//.*)?$' -and $optionIndex.ContainsKey($Matches[1])) {
                throw 'A gameplay option has no value assignment. Edit its options through the game.'
            }
            continue
        }
        $key = $match.Groups['key'].Value
        if (!$optionIndex.ContainsKey($key)) { continue }
        $option = $optionIndex[$key]
        $value = $match.Groups['value'].Value.Trim()
        if ($value.StartsWith('"') -and !$value.EndsWith('"')) { throw 'A gameplay option has a multiline value.' }
        if (!$value) { $values[$key] = $option.Default }
        elseif ($option.Choices) {
            $number = 0.0
            $values[$key] = if ([double]::TryParse($value, [Globalization.NumberStyles]::Float, $invariant, [ref]$number) -and
                ![double]::IsInfinity($number) -and ![double]::IsNaN($number)) { $number.ToString('G', $invariant) }
                else { $option.Default }
        }
        else { $values[$key] = if ($value -ceq 'true') { 'true' } else { 'false' } }
        # X-Ray lowercases section names. Keys keep case, with the later exact
        # assignment taking precedence when a key occurs more than once.
        $positions[$key] = $i
    }
    if ($null -eq $header) { throw 'The gameplay options file has no [mm_options] section.' }
    [pscustomobject]@{
        Revision = [Convert]::ToBase64String($Bytes)
        Header = $header
        Parts = $parts
        Values = $values
        Positions = $positions
    }
}

function Get-AwpGameplayOptions([string]$InstallRoot) {
    $path = Get-AwpGameplayOptionPath $InstallRoot
    Assert-AwpLocalPath $path
    if (![IO.File]::Exists($path)) { throw 'This installation has no editable gameplay options file.' }
    $snapshot = Read-AwpGameplayOptionBytes ([IO.File]::ReadAllBytes($path))
    Add-Member -InputObject $snapshot -NotePropertyName Path -NotePropertyValue $path
    $snapshot
}

function Save-AwpGameplayOptions([string]$InstallRoot, $Snapshot, [hashtable]$Values) {
    $path = Get-AwpGameplayOptionPath $InstallRoot
    if (![string]::Equals($path, $Snapshot.Path, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The game installation changed. Reload its gameplay options.'
    }
    $changes = [ordered]@{}
    foreach ($option in $modOptions) {
        $key = $option.Key
        if (!$Values.ContainsKey($key) -or $Values[$key] -ceq $Snapshot.Values[$key]) { continue }
        $allowed = if ($option.Choices) { $option.Choices } else { 'true','false' }
        if ($Values[$key] -cnotin $allowed) { throw "Choose a valid value for $($option.Label)." }
        $changes[$key] = $Values[$key]
    }
    if (!$changes.Count) { return 0 }

    $client = Join-Path $InstallRoot 'bin\xrEngine.exe'
    $profile = Join-Path $InstallRoot 'appdata'
    Assert-AwpLocalPath $path
    $lock = Open-AwpProfileLock $profile $client
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.awp-gameplay-' + [guid]::NewGuid().ToString('n') + '.tmp')
    try {
        Assert-AwpLocalPath $path
        $guard = [IO.File]::Open($path, 'Open', 'Read', ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        try {
            $buffer = [IO.MemoryStream]::new()
            try { $guard.CopyTo($buffer); $bytes = $buffer.ToArray() }
            finally { $buffer.Dispose() }
            if ([Convert]::ToBase64String($bytes) -cne $Snapshot.Revision) {
                throw 'Gameplay options changed on disk. Reload before applying your edits.'
            }
            $current = Read-AwpGameplayOptionBytes $bytes
            $newLines = @()
            foreach ($key in $changes.Keys) {
                if ($current.Positions.ContainsKey($key)) {
                    $i = $current.Positions[$key]
                    $match = $iniLine.Match($current.Parts[$i])
                    $current.Parts[$i] = $match.Groups['prefix'].Value + $changes[$key] + $match.Groups['suffix'].Value
                }
                else { $newLines += "        $key = $($changes[$key])" }
            }
            if ($newLines.Count) {
                $i = $current.Header
                $end = if ($current.Parts.Count -gt $i + 1) { $current.Parts[$i + 1] } else { [Environment]::NewLine }
                $current.Parts[$i] += $end + ($newLines -join $end)
            }

            [IO.File]::WriteAllBytes($temporary, $byteEncoding.GetBytes(($current.Parts -join '')))
            Assert-AwpGameStopped $client
            [IO.File]::Replace($temporary, $path, [NullString]::Value)
            return $changes.Count
        }
        finally { $guard.Dispose() }
    }
    finally {
        try { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        finally { $lock.Dispose() }
    }
}

Export-ModuleMember -Function Get-AwpGameplayOptionDefinitions, Get-AwpGameplayOptions, Save-AwpGameplayOptions
