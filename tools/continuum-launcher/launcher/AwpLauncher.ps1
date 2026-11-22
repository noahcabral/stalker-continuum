param([switch]$Preview, [switch]$VerifyLayout, [switch]$Portable, [string]$Origin, [string]$LauncherUpdateRequest)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AwpInstallUi.ps1')
Set-LauncherInstallRoot (Get-AwpRememberedRoot)

function Test-LaunchPlan {
    if (!$plan) { throw 'Choose an installation folder first.' }
    foreach ($path in $plan.Launcher, $plan.Client, (Join-Path $installRoot 'fsgame.ltx')) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing standalone file: $path"
        }
    }
}

if ($Preview) {
    Test-LaunchPlan
    $plan
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'AwpAddons.psm1') -Force
$reader = [Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'AwpLauncher.xaml'))
try { $form = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }

function Get-Control([string]$Name) {
    $control = $form.FindName($Name)
    if (-not $control) { throw "Launcher control is missing: $Name" }
    $control
}

$status = Get-Control Status
$play = Get-Control Play
$update = Get-Control Update
$pages = 'Home', 'Saves', 'Addons', 'Settings'
(Get-Control GamePath).Text = $installRoot
$art = @{ SidebarArt='hero'; HeroArt='hero'; SponsorArt='sponsor'; Tile1='tile1'; Tile2='tile2'; Tile3='tile3' }
foreach ($entry in $art.GetEnumerator()) {
    $path = Join-Path $PSScriptRoot "launcher-art\$($entry.Value).jpg"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-Control $entry.Key).Source = [Windows.Media.Imaging.BitmapImage]::new([Uri]::new($path))
    }
}

. (Join-Path $PSScriptRoot 'AwpProfileUi.ps1')

function Show-Page([string]$Page) {
    foreach ($name in $pages) {
        $active = $name -eq $Page
        (Get-Control ($name + 'Page')).Visibility = if ($active) { 'Visible' } else { 'Collapsed' }
        $tab = Get-Control ($name + 'Tab')
        $tab.Foreground = if ($active) { $form.FindResource('Gold') } else { '#ABABA6' }
        $tab.Background = if ($active) { '#23221B' } else { 'Transparent' }
        $tab.BorderThickness = if ($active) { [Windows.Thickness]::new(2,0,0,0) } else { [Windows.Thickness]::new(0) }
    }
    if ($Page -eq 'Addons') { Update-AddonsList }
    if ($Page -in 'Home', 'Saves') { Update-SaveLabel }
    if ($Page -eq 'Settings' -and !$script:settingsSnapshot) { Reload-AwpSettings }
}

function Update-AddonsList {
    $list = Get-Control AddonList
    $summary = Get-Control AddonSummary
    try {
        $installed = @(if ($installRoot) { Get-AwpAddons -InstallRoot $installRoot })
        $list.ItemsSource = $installed
        $list.Visibility = if ($installed.Count) { 'Visible' } else { 'Collapsed' }
        $summary.Text = switch ($installed.Count) {
            0 { 'No installed add-ons detected.' }
            1 { '1 installed add-on' }
            default { "$($installed.Count) installed add-ons" }
        }
    }
    catch {
        $list.ItemsSource = $null
        $list.Visibility = 'Collapsed'
        $summary.Text = "Could not read add-ons. $($_.Exception.Message)"
    }
}

function Open-LocalPath([string]$Path) {
    try { Invoke-Item -LiteralPath $Path } catch { $status.Text = $_.Exception.Message }
}

(Get-Control HomeTab).Add_Click({ Show-Page Home })
(Get-Control SavesTab).Add_Click({ Show-Page Saves })
(Get-Control AddonsTab).Add_Click({ Show-Page Addons })
(Get-Control SettingsTab).Add_Click({ Show-Page Settings })
(Get-Control SavesCard).Add_Click({ Show-Page Saves })
(Get-Control AddonsCard).Add_Click({ Show-Page Addons })
(Get-Control SettingsCard).Add_Click({ Show-Page Settings })
(Get-Control RefreshAddons).Add_Click({ Update-AddonsList })
(Get-Control OpenSaves).Add_Click({ Open-LocalPath $saves })
(Get-Control OpenAddons).Add_Click({ Open-LocalPath $gamedata })
(Get-Control OpenGame).Add_Click({ Open-LocalPath $installRoot })
(Get-Control Minimize).Add_Click({ $form.WindowState = 'Minimized' })
(Get-Control Maximize).Add_Click({ $form.WindowState = if ($form.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
(Get-Control Close).Add_Click({ $form.Close() })
(Get-Control TitleBar).Add_MouseLeftButtonDown({ $form.DragMove() })

$setup = @{}
Initialize-AwpInstallUi
Update-AwpRootLabels

Show-Page Home
if ($VerifyLayout) {
    if ($installRoot -and !$Portable) { Test-LaunchPlan }
    foreach ($page in $pages) { Show-Page $page }
    $form.Close()
    $plan
    return
}
Start-AwpInitialProbe
[void]$form.ShowDialog()
