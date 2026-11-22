Import-Module (Join-Path $PSScriptRoot 'AwpSaves.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AwpSettings.psm1') -Force
. (Join-Path $PSScriptRoot 'AwpGameplayOptionsUi.ps1')

$script:settingsSnapshot = $null
$settingDefinitions = @(Get-AwpSettingDefinitions)
$settingInputs = @{}
$settingsSections = Get-Control SettingsSections

function New-AwpSettingInput($Entry, [Windows.Controls.Primitives.UniformGrid]$Grid) {
    $cell = [Windows.Controls.StackPanel]::new()
    $cell.Margin = [Windows.Thickness]::new(0,0,18,12)
    $title = $Entry.Label
    $help = $Entry.Help
    if ($Entry.Kind -in 'Integer','Number') {
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $range = '{0}-{1}' -f ([Convert]::ToString($Entry.Min, $culture)), ([Convert]::ToString($Entry.Max, $culture))
        $title = "$title ($range)"
    }
    if ($Entry.Kind -in 'Toggle','Switch') {
        $inputControl = [Windows.Controls.CheckBox]::new()
        $inputControl.Content = [Windows.Controls.TextBlock]@{ Text=$title; TextWrapping='Wrap' }
        $inputControl.Foreground = '#E3E1D8'
        $inputControl.Margin = [Windows.Thickness]::new(0,6,0,0)
    }
    else {
        if ($Entry.Kind -in 'Choice','RuntimeChoice') {
            $inputControl = [Windows.Controls.ComboBox]::new()
            $inputControl.DisplayMemberPath = 'Label'
            $inputControl.SelectedValuePath = 'Value'
            $inputControl.ItemsSource = @(foreach ($choice in $Entry.Choices) {
                [pscustomobject]@{ Value = $choice[0]; Label = $choice[1] }
            })
            $inputControl.MinHeight = 29
        }
        else {
            $inputControl = [Windows.Controls.TextBox]::new()
            $inputControl.MaxLength = 30
        }
        $label = [Windows.Controls.Label]::new()
        $label.Content = [Windows.Controls.TextBlock]@{ Text=$title; TextWrapping='Wrap' }
        $label.Target = $inputControl
        [void]$cell.Children.Add($label)
    }
    [Windows.Automation.AutomationProperties]::SetName($inputControl, $title)
    [Windows.Automation.AutomationProperties]::SetAutomationId($inputControl, $Entry.Key)
    if ($help) {
        [Windows.Automation.AutomationProperties]::SetHelpText($inputControl, $help)
        $inputControl.ToolTip = $help
    }
    [void]$cell.Children.Add($inputControl)
    [void]$Grid.Children.Add($cell)
    $inputControl
}

foreach ($group in ($settingDefinitions | Group-Object { $_.Group })) {
    $tab = [Windows.Controls.TabItem]::new()
    $tab.Header = $group.Name
    $tab.Foreground = '#2E2A22'
    $grid = [Windows.Controls.Primitives.UniformGrid]::new()
    $grid.Columns = 2
    $grid.Margin = [Windows.Thickness]::new(12,12,0,0)
    $scroll = [Windows.Controls.ScrollViewer]::new()
    $scroll.MaxHeight = 386
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Content = $grid
    $tab.Content = $scroll
    foreach ($entry in $group.Group) {
        $settingInputs[$entry.Key] = New-AwpSettingInput $entry $grid
    }
    [void]$settingsSections.Items.Add($tab)
}
$settingsSections.SelectedIndex = 0
Initialize-AwpGameplayOptionsUi $settingsSections

function Update-AwpRendererControls {
    $renderer = $settingInputs.renderer.SelectedItem.Value
    foreach ($entry in $settingDefinitions) {
        if ($entry.Renderers) { $settingInputs[$entry.Key].IsEnabled = $renderer -in $entry.Renderers }
    }
    $sun = $settingInputs.r2_sun_quality
    $quality = $sun.SelectedValue
    if (!$quality -and $script:settingsSnapshot) { $quality = $script:settingsSnapshot.Values.r2_sun_quality }
    $options = $settingDefinitions | Where-Object { $_.Key -eq 'r2_sun_quality' }
    $sun.ItemsSource = @(foreach ($choice in $options.Choices) {
        if ($renderer -ne 'renderer_rgl' -or $choice[0] -notin 'st_opt_ultra','st_opt_extreme') {
            [pscustomobject]@{ Label=$choice[1]; Value=$choice[0] }
        }
    })
    $sun.SelectedValue = $quality
}

function Update-SaveLabel {
    $active = Get-Control SaveList
    $removed = Get-Control RemovedSaveList
    $selected = $active.SelectedItem.FileName
    try {
        $rows = @(if ($saves) { Get-AwpSaves $saves })
        $active.ItemsSource = $rows
        if ($selected) { $active.SelectedItem = $rows | Where-Object FileName -CEQ $selected | Select-Object -First 1 }
        $removed.ItemsSource = @(if ($saves) { Get-AwpRemovedSaves $saves })
        $label = if (!$saves) { 'Choose an installation folder' }
                 elseif ($rows.Count) { "Latest save: $($rows[0].Name)" } else { 'No saves found' }
        (Get-Control HomeSave).Text = $label
        (Get-Control LatestSave).Text = $label
        (Get-Control RemovedSavesPanel).Visibility = if ($removed.Items.Count) { 'Visible' } else { 'Collapsed' }
    }
    catch {
        (Get-Control LatestSave).Text = $_.Exception.Message
        (Get-Control HomeSave).Text = 'Could not read saves'
    }
}

function Confirm-AwpSaveRemoval([string]$Name) {
    $text = 'Delete "{0}" from the game save list? You can restore it from Removed saves.' -f $Name
    [Windows.MessageBox]::Show($form, $text, 'Delete save', 'YesNo', 'Warning', 'No') -eq 'Yes'
}

function Remove-AwpSelectedSave {
    $save = (Get-Control SaveList).SelectedItem
    if (!$save -or !(Confirm-AwpSaveRemoval $save.Name)) { return }
    try {
        Move-AwpSaveToQuarantine $saves $plan.Client $save
        $status.Text = "Moved '$($save.Name)' to Removed saves."
    }
    catch { $status.Text = $_.Exception.Message }
    Update-SaveLabel
}

function Restore-AwpSelectedSave {
    $save = (Get-Control RemovedSaveList).SelectedItem
    if (!$save) { return }
    try {
        Restore-AwpSave $saves $plan.Client $save.Id
        $status.Text = "Restored '$($save.Name)'."
    }
    catch { $status.Text = $_.Exception.Message }
    Update-SaveLabel
}

function Reload-AwpSettings {
    $notice = Get-Control SettingsNotice
    if ($settingsSections.SelectedItem -eq $script:gameplayModEditor.Tab -and $script:gameplayModEditor.Root -ne $installRoot) {
        Reload-AwpGameplayOptionsUi
    }
    $settingsSections.IsEnabled = $false
    if (!$settings) {
        $script:settingsSnapshot = $null
        (Get-Control SettingsApply).IsEnabled = $false
        $notice.Text = 'Choose an installation folder to edit its settings.'
        return
    }
    try {
        $script:settingsSnapshot = Get-AwpSettings $settings
        foreach ($entry in $settingDefinitions) {
            $control = $settingInputs[$entry.Key]
            $value = $script:settingsSnapshot.Values[$entry.Key]
            switch ($entry.Kind) {
                { $_ -in 'Toggle','Switch' } {
                    $control.IsThreeState = $null -eq $value
                    $control.IsChecked = if ($null -eq $value) { $null } else { $value -in 'on','1' }
                    break
                }
                'Choice' { $control.SelectedValue = $value; break }
                'RuntimeChoice' {
                    $choices = @($script:settingsSnapshot.RuntimeChoices[$entry.Key])
                    $control.IsEnabled = $choices.Count -gt 0
                    $help = $entry.Help
                    if (!$choices.Count) { $help = 'A game startup log is needed to list the available choices.' }
                    if ($entry.Key -eq 'snd_device' -and $script:settingsSnapshot.RuntimeChoices.LastSoundDevice) {
                        $help += " Last startup used $($script:settingsSnapshot.RuntimeChoices.LastSoundDevice)."
                    }
                    [Windows.Automation.AutomationProperties]::SetHelpText($control, $help)
                    $control.ToolTip = $help
                    [Windows.Controls.ToolTipService]::SetShowOnDisabled($control, $true)
                    if ($value -and $value -cnotin $choices.Value) {
                        $label = if ($script:settingsSnapshot.Encoding -is [Text.UnicodeEncoding]) { $value }
                                 else { ConvertFrom-AwpLogBytes $value }
                        $label += if ($choices.Count) { ' (unavailable)' } else { ' (configured)' }
                        $choices = @([pscustomobject]@{ Label=$label; Value=$value }) + $choices
                    }
                    $control.ItemsSource = $choices
                    $control.SelectedValue = $value
                    break
                }
                default { $control.Text = [string]$value }
            }
        }
        Update-AwpRendererControls
        $settingsSections.IsEnabled = $true
        (Get-Control SettingsApply).IsEnabled = $true
        $notice.Text = ''
    }
    catch {
        $script:settingsSnapshot = $null
        (Get-Control SettingsApply).IsEnabled = $false
        $notice.Text = $_.Exception.Message
    }
}

function Apply-AwpSettings {
    $notice = Get-Control SettingsNotice
    if (!$script:settingsSnapshot) { return }
    $values = @{}
    foreach ($entry in $settingDefinitions) {
        $key = $entry.Key
        $control = $settingInputs[$key]
        if (!$control.IsEnabled) { continue }
        switch ($entry.Kind) {
            'Toggle' {
                if ($null -ne $control.IsChecked) { $values[$key] = if ($control.IsChecked) { 'on' } else { 'off' } }
                break
            }
            'Switch' {
                if ($null -ne $control.IsChecked) { $values[$key] = if ($control.IsChecked) { '1' } else { '0' } }
                break
            }
            { $_ -in 'Choice','RuntimeChoice' } {
                if ($null -ne $control.SelectedValue) { $values[$key] = $control.SelectedValue }
                break
            }
            default {
                if ($control.Text -or $script:settingsSnapshot.Values[$key]) { $values[$key] = $control.Text }
            }
        }
    }
    try {
        $saved = Save-AwpSettings $settings $plan.Client $script:settingsSnapshot $values
        Reload-AwpSettings
        $notice.Text = if ($saved) { 'Settings saved. They take effect next time the game starts.' } else { 'No settings changed.' }
    }
    catch { $notice.Text = $_.Exception.Message }
}

(Get-Control SaveList).Add_SelectionChanged({ (Get-Control DeleteSave).IsEnabled = $null -ne (Get-Control SaveList).SelectedItem })
(Get-Control RemovedSaveList).Add_SelectionChanged({ (Get-Control RestoreSave).IsEnabled = $null -ne (Get-Control RemovedSaveList).SelectedItem })
(Get-Control Refresh).Add_Click({ Update-SaveLabel })
(Get-Control DeleteSave).Add_Click({ Remove-AwpSelectedSave })
(Get-Control RestoreSave).Add_Click({ Restore-AwpSelectedSave })
(Get-Control SettingsApply).Add_Click({ Apply-AwpSettings })
(Get-Control SettingsReload).Add_Click({ Reload-AwpSettings })
$settingInputs.renderer.Add_SelectionChanged({ Update-AwpRendererControls })
