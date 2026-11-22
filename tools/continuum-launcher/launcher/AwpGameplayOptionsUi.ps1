Import-Module (Join-Path $PSScriptRoot 'AwpGameplayOptions.psm1') -Force

$script:gameplayModEditor = $null

function Add-AwpGameplayOptionInput($Definition, $Grid) {
    $cell = [Windows.Controls.StackPanel]::new()
    $cell.Margin = [Windows.Thickness]::new(0,0,18,12)
    $title = [Windows.Controls.TextBlock]@{ Text=$Definition.Label; TextWrapping='Wrap' }
    if ($Definition.Choices) {
        $control = [Windows.Controls.ComboBox]::new()
        $control.DisplayMemberPath = 'Label'
        $control.SelectedValuePath = 'Value'
        $control.MinHeight = 29
        $label = [Windows.Controls.Label]::new()
        $label.Content = $title
        $label.Target = $control
        [void]$cell.Children.Add($label)
    }
    else {
        $control = [Windows.Controls.CheckBox]::new()
        $control.Foreground = '#E3E1D8'
        $control.Margin = [Windows.Thickness]::new(0,6,0,0)
        $control.Content = $title
    }
    [Windows.Automation.AutomationProperties]::SetName($control, $Definition.Label)
    [Windows.Automation.AutomationProperties]::SetAutomationId($control, ('axr_' + $Definition.Key))
    if ($Definition.Help) {
        [Windows.Automation.AutomationProperties]::SetHelpText($control, $Definition.Help)
        $control.ToolTip = $Definition.Help
        [Windows.Controls.ToolTipService]::SetShowOnDisabled($control, $true)
    }
    [void]$cell.Children.Add($control)
    [void]$Grid.Children.Add($cell)
    $control
}

function Add-AwpGameplayOptionsTab([Windows.Controls.TabControl]$Sections) {
    $tab = [Windows.Controls.TabItem]@{ Header='Gameplay mods'; Foreground='#2E2A22' }
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(12,12,0,0)
    $toolbar = [Windows.Controls.WrapPanel]::new()
    $apply = [Windows.Controls.Button]@{
        Content='Save mod settings'; Margin=[Windows.Thickness]::new(0,0,12,6); IsEnabled=$false
    }
    $reload = [Windows.Controls.Button]@{ Content='Discard and reload mods'; Margin=[Windows.Thickness]::new(0,0,0,6) }
    [void]$toolbar.Children.Add($apply)
    [void]$toolbar.Children.Add($reload)
    $scope = [Windows.Controls.TextBlock]@{
        Text='These settings apply to the entire game installation. Changes take effect the next time the game starts.'
        TextWrapping='Wrap'
        Foreground='#B8B6AD'
        Margin=[Windows.Thickness]::new(0,0,12,10)
    }
    $notice = [Windows.Controls.TextBlock]@{
        TextWrapping='Wrap'; Foreground='#B8B6AD'; Margin=[Windows.Thickness]::new(0,0,12,10)
    }
    [Windows.Automation.AutomationProperties]::SetLiveSetting($notice, 'Polite')
    $scroll = [Windows.Controls.ScrollViewer]@{ MaxHeight=330; VerticalScrollBarVisibility='Auto'; HorizontalScrollBarVisibility='Disabled' }
    $grid = [Windows.Controls.Primitives.UniformGrid]@{ Columns=2; IsEnabled=$false }
    $controls = @{}
    $definitions = @(Get-AwpGameplayOptionDefinitions)
    foreach ($definition in $definitions) {
        $controls[$definition.Key] = Add-AwpGameplayOptionInput $definition $grid
    }
    $scroll.Content = $grid
    foreach ($child in $scope,$toolbar,$notice,$scroll) { [void]$panel.Children.Add($child) }
    $tab.Content = $panel
    $script:gameplayModEditor = @{
        Tab=$tab; Controls=$controls; Definitions=$definitions; Apply=$apply; Reload=$reload
        Grid=$grid; Notice=$notice; Root=$null; Snapshot=$null
    }
    $apply.Add_Click({ Save-AwpGameplayOptionsUi })
    $reload.Add_Click({ Reload-AwpGameplayOptionsUi })
    $controls.enable_heli_spawn.Add_Checked({ $script:gameplayModEditor.Controls.enable_heli_engine_sound.IsEnabled = $true })
    $controls.enable_heli_spawn.Add_Unchecked({ $script:gameplayModEditor.Controls.enable_heli_engine_sound.IsEnabled = $false })
    [void]$Sections.Items.Add($tab)
    $tab
}

function Reload-AwpGameplayOptionsUi {
    $editor = $script:gameplayModEditor
    $editor.Root = $installRoot
    $editor.Snapshot = $null
    $editor.Grid.IsEnabled = $false
    $editor.Apply.IsEnabled = $false
    if (!$installRoot) {
        $editor.Notice.Text = 'Choose an installation folder to edit its gameplay mod settings.'
        return
    }
    try {
        $editor.Snapshot = Get-AwpGameplayOptions $installRoot
        foreach ($definition in $editor.Definitions) {
            $control = $editor.Controls[$definition.Key]
            $value = $editor.Snapshot.Values[$definition.Key]
            if ($definition.Choices) {
                $choices = @(for ($i = 0; $i -lt $definition.Choices.Count; $i++) {
                    $label = if ($definition.Labels) { $definition.Labels[$i] } else { $definition.Choices[$i] }
                    [pscustomobject]@{ Value=$definition.Choices[$i]; Label=$label }
                })
                if ($value -cnotin $definition.Choices) {
                    $choices += [pscustomobject]@{ Value=$value; Label="$value (configured)" }
                }
                $control.ItemsSource = $choices
                $control.SelectedValue = $value
            }
            else { $control.IsChecked = $value -ceq 'true' }
        }
        $editor.Controls.enable_heli_engine_sound.IsEnabled = [bool]$editor.Controls.enable_heli_spawn.IsChecked
        $editor.Notice.Text = ''
        $editor.Grid.IsEnabled = $true
        $editor.Apply.IsEnabled = $true
    }
    catch { $editor.Notice.Text = $_.Exception.Message }
}

function Save-AwpGameplayOptionsUi {
    $editor = $script:gameplayModEditor
    if (!$editor.Snapshot) { return }
    $draft = @{}
    foreach ($definition in $editor.Definitions) {
        $control = $editor.Controls[$definition.Key]
        if (!$control.IsEnabled) { continue }
        if ($definition.Choices) { $draft[$definition.Key] = $control.SelectedValue }
        else { $draft[$definition.Key] = if ($control.IsChecked) { 'true' } else { 'false' } }
    }
    try {
        $count = Save-AwpGameplayOptions $installRoot $editor.Snapshot $draft
        Reload-AwpGameplayOptionsUi
        $editor.Notice.Text = if ($count) { 'Gameplay mod settings saved.' } else { 'No gameplay mod settings changed.' }
    }
    catch { $editor.Notice.Text = $_.Exception.Message }
}

function Initialize-AwpGameplayOptionsUi([Windows.Controls.TabControl]$Sections) {
    $tab = Add-AwpGameplayOptionsTab $Sections
    $Sections.Add_SelectionChanged({
        param($sender, $eventArgs)
        if ($eventArgs.OriginalSource -ne $sender) { return }
        $isGameplayModTab = $sender.SelectedItem -eq $script:gameplayModEditor.Tab
        foreach ($name in 'SettingsApply','SettingsReload','SettingsNotice') {
            (Get-Control $name).Visibility = if ($isGameplayModTab) { 'Collapsed' } else { 'Visible' }
        }
        if ($isGameplayModTab -and ($script:gameplayModEditor.Root -ne $installRoot -or !$script:gameplayModEditor.Snapshot)) {
            Reload-AwpGameplayOptionsUi
        }
    })
}
