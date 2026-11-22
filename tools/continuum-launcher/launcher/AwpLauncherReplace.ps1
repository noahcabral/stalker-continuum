param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][int]$ParentId)

$ErrorActionPreference = 'Stop'
$bundle = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$tempPrefix = [IO.Path]::GetTempPath().TrimEnd('\') + '\AwpLauncher-'
if (!$bundle.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $bundle.Substring($tempPrefix.Length) -cnotmatch '^[a-f0-9]{32}$' -or
    ((Get-Item -LiteralPath $bundle).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Invalid launcher update folder.'
}

$targetPath = [IO.Path]::GetFullPath($Target)
$newPath = Join-Path $bundle 'next-launcher.exe'
$sidecar = $targetPath + '.' + [Guid]::NewGuid().ToString('N')
$prepared = $sidecar + '.new'
$backup = $sidecar + '.previous'
$replaced = $false
$completed = $false
try {
    $request = [IO.File]::ReadAllLines((Join-Path $bundle 'launcher-update.request'))
    if ($request.Count -ne 2 -or $request[0] -cnotmatch '^\d+\.\d+\.\d+$' -or
        $request[1] -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid launcher update request.' }
    $previous = Get-Item -LiteralPath $targetPath
    if ($previous.PSIsContainer -or ($previous.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Start the launcher from a regular executable file.'
    }
    $parent = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
    if ($parent -and $parent.Path -eq $targetPath -and !$parent.WaitForExit(15000)) {
        throw 'The previous launcher is still running.'
    }
    $oldAssembly = [Reflection.AssemblyName]::GetAssemblyName($targetPath)
    $newAssembly = [Reflection.AssemblyName]::GetAssemblyName($newPath)
    if ($oldAssembly.Name -cne $newAssembly.Name -or $newAssembly.Version -le $oldAssembly.Version -or
        $newAssembly.Version.ToString(3) -cne $request[0]) { throw 'Launcher update version changed.' }

    [IO.File]::Copy($newPath, $prepared)
    $inputStream = [IO.File]::OpenRead($prepared)
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($algorithm.ComputeHash($inputStream)).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    } finally { $inputStream.Dispose() }
    if ($digest -cne $request[1]) {
        throw 'Launcher update checksum changed.'
    }
    [IO.File]::Replace($prepared, $targetPath, $backup)
    $replaced = $true
    $next = Start-Process -FilePath $targetPath -WorkingDirectory $previous.DirectoryName -PassThru
    try {
        if ($next.WaitForExit(1800) -and $next.ExitCode -ne 0) {
            throw 'The updated launcher did not start.'
        }
    } finally { $next.Dispose() }
    $completed = $true
} catch {
    if ($replaced -and [IO.File]::Exists($backup)) {
        try {
            [IO.File]::Replace($backup, $targetPath, $null)
            Start-Process -FilePath $targetPath -WorkingDirectory ([IO.Path]::GetDirectoryName($targetPath))
        } catch { }
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Continuum launcher update', 'OK', 'Error')
    exit 1
} finally {
    if ([IO.File]::Exists($prepared)) { [IO.File]::Delete($prepared) }
    if ($completed -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    Remove-Item -LiteralPath $bundle -Force -Recurse -ErrorAction SilentlyContinue
}
