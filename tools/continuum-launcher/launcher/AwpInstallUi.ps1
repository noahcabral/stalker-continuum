Import-Module (Join-Path $PSScriptRoot 'AwpVersionCheck.psm1')

function Set-AwpVersionSummary([string]$State, [string]$GameVersion, $VersionResult = $null) {
    $game = if ($GameVersion) { $GameVersion } elseif ($State -eq 'Absent') { 'Not installed' } else { 'Unversioned' }
    $rows = @("Launcher $($setup.LauncherVersion)", "Game $game")
    if ($VersionResult) {
        if ($VersionResult.LauncherUpdate) { $rows += "Launcher $($VersionResult.LauncherUpdate) is available." }
        elseif ($VersionResult.LatestLauncherVersion) { $rows += "Latest published launcher $($VersionResult.LatestLauncherVersion)." }
        elseif (!$VersionResult.Message) { $rows += 'No launcher release is published.' }
        if ($VersionResult.Update) { $rows += "Game update $($VersionResult.Update) is available." }
        if ($VersionResult.Message) { $rows += $VersionResult.Message }
    }
    $setup.Versions.Text = $rows -join "`n"
}

function Show-AwpVerificationResult($Result) {
    $status.Text = $Result.Message
    if (!$Result.Available -or !(($Result.Missing.Count + $Result.Changed.Count + $Result.Unreadable.Count))) { return }
    $sections = foreach ($label in 'Missing','Changed','Unreadable') {
        $paths = @($Result.$label)
        if ($paths.Count) { "$label ($($paths.Count))`n" + ($paths -join "`n") }
    }
    $dialog = [Windows.Window]::new()
    $dialog.Title = 'Game file verification'
    $dialog.Owner = $form
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Width = 650
    $dialog.Height = 440
    $details = [Windows.Controls.TextBox]::new()
    $details.Text = $sections -join "`n`n"
    $details.IsReadOnly = $true
    $details.VerticalScrollBarVisibility = 'Auto'
    $details.HorizontalScrollBarVisibility = 'Auto'
    $details.Margin = [Windows.Thickness]::new(16)
    $dialog.Content = $details
    [void]$dialog.ShowDialog()
}

function Get-AwpRememberedRoot {
    if (!$Portable) { return (Split-Path -Parent $PSScriptRoot) }
    if ($Origin) {
        foreach ($identity in 'Launch-Standalone.cmd','Launch-AWP-GUI.cmd','appdata\awp-user.ltx','.awp-baseline-release') {
            if (Test-Path -LiteralPath (Join-Path $Origin $identity) -PathType Leaf) { return $Origin }
        }
    }
    $known = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AWP Standalone Launcher\game-root.txt'
    if (Test-Path -LiteralPath $known -PathType Leaf) {
        $value = [IO.File]::ReadAllText($known).Trim()
        if ($value -and (Test-Path -LiteralPath $value -PathType Container)) { return $value }
    }
    return ''
}

function Set-LauncherInstallRoot([AllowEmptyString()][string]$Root) {
    $script:installRoot = $Root
    $script:appdata, $script:saves, $script:settings, $script:gamedata, $script:plan = $null, $null, $null, $null, $null
    if (!$Root) { return }
    $script:appdata = Join-Path $Root 'appdata'
    $script:saves = Join-Path $appdata 'savedgames'
    $script:settings = Join-Path $appdata 'awp-user.ltx'
    $script:gamedata = Join-Path $Root 'gamedata'
    $script:plan = [pscustomobject]@{
        WorkingDirectory = $Root
        Launcher = Join-Path $Root 'Launch-Standalone.cmd'
        Client = Join-Path $Root 'bin\xrEngine.exe'
        Profile = $appdata
    }
}

function Save-AwpRoot {
    if (!$Portable -or !$installRoot) { return }
    try {
        $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AWP Standalone Launcher'
        [void][IO.Directory]::CreateDirectory($dir)
        $target = Join-Path $dir 'game-root.txt'
        if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        [IO.File]::WriteAllText($target, $installRoot)
    } catch { }
}

function Update-AwpRootLabels {
    (Get-Control GamePath).Text = if ($installRoot) { $installRoot } else { 'Choose an installation folder' }
    foreach ($id in 'OpenGame','OpenSaves','OpenAddons') {
        (Get-Control $id).IsEnabled = [bool]$installRoot
    }
    Update-SaveLabel
    if (Get-Command Update-AddonsList -ErrorAction SilentlyContinue) { Update-AddonsList }
    $script:settingsSnapshot = $null
    if ((Get-Control SettingsPage).Visibility -eq 'Visible') { Reload-AwpSettings }
}

function Set-AwpInstallActions([string]$State, [string]$Message = '') {
    $setup.State = $State
    $setup.VerifyFiles.IsEnabled = $State -in 'Ready','Broken'
    if ($State -in 'Absent','Checking') { Set-AwpVersionSummary 'Absent' '' }
    $update.Visibility = 'Collapsed'
    $play.IsEnabled = $State -in 'Ready','Recovery','RepairRecovery','Broken','Absent'
    $play.Content = switch ($State) {
        'Ready' { 'PLAY' }
        'Broken' { 'REPAIR' }
        'Recovery' { 'REPAIR' }
        'RepairRecovery' { 'REPAIR' }
        'Checking' { 'CHECKING' }
        default { 'INSTALL' }
    }
    $status.Text = if ($Message) { $Message } else {
        switch ($State) {
            'Ready' { 'Ready to play' }
            'Broken' { 'Some standalone files are missing or damaged. Choose Repair to review the baseline recovery.' }
            'Recovery' { 'An interrupted update needs recovery.' }
            'RepairRecovery' { 'An interrupted repair needs recovery.' }
            'Checking' { 'Checking the installation...' }
            default { 'Choose Install to select a folder for S.T.A.L.K.E.R.: Continuum.' }
        }
    }
}

function Select-AwpRoot {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'Choose an existing AWP installation or an empty folder for a new install.'
        $dialog.ShowNewFolderButton = $true
        if ($installRoot -and (Test-Path -LiteralPath $installRoot -PathType Container)) { $dialog.SelectedPath = $installRoot }
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $folder = [IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
            if ([IO.Path]::GetPathRoot($dialog.SelectedPath).TrimEnd('\') -eq $folder) {
                $status.Text = 'Choose a folder inside the drive.'
                return ''
            }
            return $folder
        }
    } finally { $dialog.Dispose() }
    return ''
}

function Confirm-AwpWork([string]$Action) {
    $prompt = if ($Action -eq 'Install') {
        "Install S.T.A.L.K.E.R.: Continuum in this folder?`n`n$installRoot`n`nAllow around 29 GiB of free space."
    } elseif ($setup.Damaged.Count) {
        $list = $setup.Damaged -join "`n"
        "Apply the managed file repairs below in $installRoot`?`n`n$list`n`nRepair keeps originals in the repair backups folder. Saves and settings stay in place. Missing files may require a 26.97 GiB download."
    } else { "Check this installation and restore missing files?`n`n$installRoot`n`nExisting saves and settings stay in place. Missing files may require a 26.97 GiB download." }
    [Windows.MessageBox]::Show($form, $prompt, 'S.T.A.L.K.E.R.: Continuum', 'YesNo', 'Question') -eq 'Yes'
}

function Invoke-AwpDestinationPrompt {
    $folder = Select-AwpRoot
    if (!$folder) { return }
    Set-LauncherInstallRoot $folder
    Update-AwpRootLabels
    Set-AwpInstallActions 'Checking'
    $setup.PromptInstall = $true
    Start-AwpInstallWork 'Scan'
}

function Show-AwpInitialFolderPicker {
    if ($Portable -and !$setup.AutoPrompted -and $setup.State -eq 'Absent') {
        $setup.AutoPrompted = $true
        Invoke-AwpDestinationPrompt
    }
}

function Start-AwpInstallWork([string]$Action, [bool]$Background = $false) {
    if ($setup.Process) { return }
    try {
        $setup.Output = [IO.Path]::GetTempFileName()
        $setup.Errors = [IO.Path]::GetTempFileName()
        $setup.Action = $Action
        $setup.Background = $Background
        $worker = Join-Path $PSScriptRoot 'AwpInstallWorker.ps1'
        $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -Action {1}' -f $worker,$Action
        if ($installRoot) { $arguments += ' -InstallRoot "{0}"' -f $installRoot.TrimEnd('\') }
        if ($Action -eq 'Repair' -and $setup.RepairApproval) { $arguments += ' -RepairApproval ' + $setup.RepairApproval }
        if ($Action -eq 'UpdateLauncher') { $arguments += ' -LauncherUpdateRequest "{0}"' -f $LauncherUpdateRequest }
        $setup.Process = Start-Process -FilePath $hostPath -ArgumentList $arguments -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $setup.Output -RedirectStandardError $setup.Errors
        $setup.Locate.IsEnabled = $false
        $setup.CheckVersions.IsEnabled = $false
        $setup.VerifyFiles.IsEnabled = $false
        $setup.LauncherUpdateButton.IsEnabled = $false
        if ($Action -eq 'CheckVersions' -and !$Background) { $status.Text = 'Checking versions...' }
        if ($Action -notin 'CheckUpdate','CheckVersions') {
            $play.IsEnabled = $false
            $update.IsEnabled = $false
        }
        if ($Action -in 'Install','Repair','Update','Recover','RecoverRepair','VerifyFiles','UpdateLauncher') {
            $setup.Progress.Value = 0
            $setup.Progress.IsIndeterminate = $true
            $setup.Progress.Visibility = 'Visible'
            $status.Text = 'Preparing...'
        }
        $setup.Timer.Start()
    } catch {
        foreach ($file in $setup.Output,$setup.Errors) { if ($file) { [IO.File]::Delete($file) } }
        $setup.Process = $null
        $state = if ($setup.State -eq 'Checking') { 'Absent' } else { $setup.State }
        $setup.PromptInstall = $false
        $setup.Locate.IsEnabled = $true
        $setup.CheckVersions.IsEnabled = $true
        $setup.LauncherUpdateButton.IsEnabled = $true
        Set-AwpInstallActions $state $_.Exception.Message
    }
}

function Invoke-AwpPlay {
    Test-LaunchPlan
    if (Test-Path -LiteralPath (Join-Path $installRoot '.awp-update')) { throw 'Repair the interrupted update before playing.' }
    $lockFile = Join-Path $installRoot '.awp-update.lock'
    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
        try { [IO.File]::Open($lockFile, 'Open', 'Read', 'ReadWrite').Dispose() }
        catch { throw 'An update or repair is using this installation.' }
    }
    $stillRunning = Get-Process -Name xrEngine -ErrorAction SilentlyContinue | Where-Object Path -eq $plan.Client
    if ($stillRunning) { throw 'The standalone is already running.' }
    Start-Process -FilePath $env:ComSpec -ArgumentList '/d /c Launch-Standalone.cmd' `
        -WorkingDirectory $plan.WorkingDirectory -WindowStyle Hidden
    $status.Text = 'Standalone launched.'
}

function Initialize-AwpInstallUi {
    $setup.State = 'Absent'
    $setup.Process = $null
    $setup.PromptInstall = $false
    $setup.AutoPrompted = $false
    $setup.ProbeStarted = $false
    $setup.Damaged = @()
    $setup.RepairApproval = ''
    $setup.Update = $null
    $setup.Background = $false
    $setup.Progress = [Windows.Controls.ProgressBar]::new()
    $setup.Progress.Height = 7
    $setup.Progress.Margin = [Windows.Thickness]::new(0,12,0,0)
    $setup.Progress.Foreground = $form.FindResource('Gold')
    $setup.Progress.Visibility = 'Collapsed'
    $footer = $status.Parent
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(0,0,22,0)
    $panel.VerticalAlignment = 'Center'
    [void]$footer.Children.Remove($status)
    $status.Margin = [Windows.Thickness]::new(0)
    [void]$panel.Children.Add($status)
    $setup.LauncherUpdateButton = [Windows.Controls.Button]::new()
    $setup.LauncherUpdateButton.Content = 'Update launcher'
    $setup.LauncherUpdateButton.HorizontalAlignment = 'Left'
    $setup.LauncherUpdateButton.Margin = [Windows.Thickness]::new(0,8,0,0)
    $setup.LauncherUpdateButton.Visibility = 'Collapsed'
    $setup.LauncherUpdateButton.Add_Click({ Start-AwpInstallWork 'UpdateLauncher' })
    [void]$panel.Children.Add($setup.LauncherUpdateButton)
    [void]$panel.Children.Add($setup.Progress)
    [void]$footer.Children.Add($panel)

    $setup.Locate = [Windows.Controls.Button]::new()
    $setup.Locate.Content = 'Choose folder'
    $setup.Locate.Margin = [Windows.Thickness]::new(12,0,0,0)
    $gamePanel = (Get-Control OpenGame).Parent
    [void]$gamePanel.Children.Add($setup.Locate)
    $setup.LauncherVersion = Read-AwpLauncherVersion $PSScriptRoot
    $setup.Versions = [Windows.Controls.TextBlock]::new()
    $setup.Versions.Margin = [Windows.Thickness]::new(0,16,0,8)
    $setup.Versions.TextWrapping = 'Wrap'
    [void]$gamePanel.Children.Add($setup.Versions)
    $versionActions = [Windows.Controls.WrapPanel]::new()
    $setup.CheckVersions = [Windows.Controls.Button]::new()
    $setup.CheckVersions.Content = 'Check versions'
    $setup.VerifyFiles = [Windows.Controls.Button]::new()
    $setup.VerifyFiles.Content = 'Verify files'
    $setup.VerifyFiles.Margin = [Windows.Thickness]::new(12,0,0,0)
    [void]$versionActions.Children.Add($setup.CheckVersions)
    [void]$versionActions.Children.Add($setup.VerifyFiles)
    [void]$gamePanel.Children.Add($versionActions)
    $setup.CheckVersions.Add_Click({ Start-AwpInstallWork 'CheckVersions' })
    $setup.VerifyFiles.Add_Click({ Start-AwpInstallWork 'VerifyFiles' })
    $setup.Locate.Add_Click({
        $folder = Select-AwpRoot
        if (!$folder) { return }
        Set-LauncherInstallRoot $folder
        Update-AwpRootLabels
        Set-AwpInstallActions 'Checking'
        Start-AwpInstallWork 'Scan'
    })
    $play.Add_Click({
        try {
            switch ($setup.State) {
                'Ready' { Invoke-AwpPlay }
                'Recovery' { Start-AwpInstallWork 'Recover' }
                'RepairRecovery' { Start-AwpInstallWork 'RecoverRepair' }
                'Broken' { if (Confirm-AwpWork 'Repair') { Start-AwpInstallWork 'Repair' } }
                'Absent' { Invoke-AwpDestinationPrompt }
            }
        } catch { $status.Text = $_.Exception.Message }
    })
    $update.Add_Click({
        if ($setup.Update -and $setup.State -eq 'Ready') { Start-AwpInstallWork 'Update' }
    })

    $setup.Timer = [Windows.Threading.DispatcherTimer]::new()
    $setup.Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $setup.VersionTimer = [Windows.Threading.DispatcherTimer]::new()
    $setup.VersionTimer.Interval = [TimeSpan]::FromMinutes(1)
    $setup.VersionTimer.Add_Tick({ Start-AwpInstallWork 'CheckVersions' $true })
    $setup.Timer.Add_Tick({
        $row = Get-Content -LiteralPath $setup.Output -Tail 1 -ErrorAction SilentlyContinue
        $event = if ($row) { try { $row | ConvertFrom-Json -ErrorAction Stop } catch { } }
        if ($event -and $event.Kind -eq 'Progress') {
            $status.Text = $event.Message
            $setup.Progress.IsIndeterminate = $event.Percent -eq 0
            $setup.Progress.Value = $event.Percent
        }
        if (!$setup.Process.HasExited) { return }
        $setup.Timer.Stop()
        $setup.Process.WaitForExit()
        $row = Get-Content -LiteralPath $setup.Output -Tail 1 -ErrorAction SilentlyContinue
        if ($row) { try { $event = $row | ConvertFrom-Json -ErrorAction Stop } catch { } }
        $setup.Process.Dispose()
        $setup.Process = $null
        foreach ($file in $setup.Output,$setup.Errors) { [IO.File]::Delete($file) }
        $setup.Progress.Visibility = 'Collapsed'
        $setup.Locate.IsEnabled = $true
        $setup.CheckVersions.IsEnabled = $true
        $setup.VerifyFiles.IsEnabled = $setup.State -in 'Ready','Broken'
        $setup.LauncherUpdateButton.IsEnabled = $true
        $update.IsEnabled = $true
        if ($setup.Action -eq 'UpdateLauncher') {
            if ($event -and $event.Kind -eq 'Result') {
                $status.Text = $event.Message
                $form.Close()
            } else {
                $message = if ($event -and $event.Message) { $event.Message } else { 'The launcher update did not finish.' }
                Set-AwpInstallActions $setup.State $message
            }
            return
        }
        if ($setup.Action -in 'VerifyFiles','CheckVersions') {
            $play.IsEnabled = $setup.State -in 'Ready','Recovery','RepairRecovery','Broken','Absent'
            if (!$event -or $event.Kind -ne 'Result') {
                if (!$setup.Background) {
                    $status.Text = if ($event -and $event.Message) { $event.Message } else { 'The check did not finish.' }
                }
            } elseif ($setup.Action -eq 'VerifyFiles') {
                Show-AwpVerificationResult $event
            } else {
                Set-AwpVersionSummary $event.State $event.GameVersion $event
                if (!$setup.Background) { $status.Text = if ($event.Message) { $event.Message } else { 'Versions checked.' } }
                if (!$event.Message) {
                    $setup.LauncherUpdateButton.Visibility = if ($event.LauncherUpdate -and $LauncherUpdateRequest) { 'Visible' } else { 'Collapsed' }
                    $setup.Update = if ($event.State -eq 'Ready') { $event.Update } else { $null }
                    $update.Visibility = if ($setup.Update) { 'Visible' } else { 'Collapsed' }
                }
            }
            return
        }
        if ($setup.Action -eq 'CheckUpdate') {
            $setup.Update = if ($event -and $event.Kind -eq 'Result') { $event.Update } else { $null }
            $update.Visibility = if ($setup.Update) { 'Visible' } else { 'Collapsed' }
            return
        }
        if (!$event -or $event.Kind -ne 'Result') {
            $message = if ($event -and $event.Message) { $event.Message } else { 'The launcher task stopped before reporting a result.' }
            $state = if ($setup.State -eq 'Checking') { 'Absent' } else { $setup.State }
            if ($setup.Action -eq 'Update' -and (Test-Path -LiteralPath (Join-Path $installRoot '.awp-update'))) { $state = 'Recovery' }
            $setup.PromptInstall = $false
            Set-AwpInstallActions $state $message
            return
        }
        $prompt = $setup.PromptInstall
        $setup.PromptInstall = $false
        $setup.Damaged = @($event.Damaged | Where-Object { $_ })
        $setup.RepairApproval = $event.RepairApproval
        Set-AwpInstallActions $event.State $event.Message
        if ($event.State -ne 'Absent') { Set-AwpVersionSummary $event.State $event.GameVersion }
        if ($event.State -eq 'Ready') {
            Save-AwpRoot
            Update-AwpRootLabels
            Start-AwpInstallWork 'CheckVersions' $true
        } elseif ($event.State -eq 'Absent') {
            if ($prompt) { if (Confirm-AwpWork 'Install') { Start-AwpInstallWork 'Install' } }
            else { Show-AwpInitialFolderPicker }
            if (!$setup.Process) { Start-AwpInstallWork 'CheckVersions' $true }
        } else {
            Start-AwpInstallWork 'CheckVersions' $true
        }
    })
    $form.Add_Closing({
        param($sender,$event)
        if ($setup.Process) {
            if (!$setup.Process.HasExited -and $setup.Action -in 'Install','Repair','Update','Recover','RecoverRepair','UpdateLauncher') {
                $event.Cancel = $true
                $status.Text = 'Wait for the current installation task to finish.'
                return
            }
            $setup.Timer.Stop()
            try {
                if (!$setup.Process.HasExited) { $setup.Process.Kill() }
                [void]$setup.Process.WaitForExit(1000)
                foreach ($file in $setup.Output,$setup.Errors) { if ($file) { [IO.File]::Delete($file) } }
            } catch { }
            $setup.Process.Dispose()
            $setup.Process = $null
        }
        $setup.VersionTimer.Stop()
    })
    Set-AwpInstallActions 'Absent'
}

function Start-AwpInitialProbe {
    $form.Add_ContentRendered({
        if ($setup.ProbeStarted) { return }
        $setup.ProbeStarted = $true
        $setup.VersionTimer.Start()
        if ($installRoot) {
            Set-AwpInstallActions 'Checking'
            Start-AwpInstallWork 'Scan'
        } else {
            Show-AwpInitialFolderPicker
            if (!$setup.Process) { Start-AwpInstallWork 'CheckVersions' $true }
        }
    })
}
