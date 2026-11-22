param([switch]$CheckOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$worker = Join-Path $PSScriptRoot 'AwpInstallWorker.ps1'
$root = Split-Path -Parent $PSScriptRoot
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Invoke-UpdateWorker([string]$Action) {
    $result = $null
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $worker -Action $Action -InstallRoot $root |
        ForEach-Object {
            $message = $_ | ConvertFrom-Json
            switch ($message.Kind) {
                'Progress' { Write-Host "$($message.Percent)% $($message.Message)" }
                'Result' { $result = $message }
                'Error' { throw $message.Message }
            }
        }
    if ($LASTEXITCODE -ne 0 -or !$result) { throw 'The standalone update worker did not return a result.' }
    return $result
}

try {
    if (!(Test-Path -LiteralPath $worker -PathType Leaf)) {
        throw 'The verified update worker is missing. Start the current standalone launcher.'
    }
    if (!$CheckOnly -and (Invoke-UpdateWorker Scan).State -eq 'Recovery') {
        $recovered = Invoke-UpdateWorker Recover
        Write-Output $recovered.Message
    }
    $available = Invoke-UpdateWorker CheckUpdate
    if (!$available.Update) {
        Write-Output 'No verified update applies to this installation.'
    } elseif ($CheckOnly) {
        Write-Output "Continuum $($available.Update) is available."
    } else {
        $completed = Invoke-UpdateWorker Update
        Write-Output $completed.Message
    }
    exit 0
} catch {
    Write-Output "Update failed. $($_.Exception.Message)"
    exit 1
}
