[CmdletBinding()]
param(
    [string]$ConfigFile
)

# Resolve default config path dynamically if not explicitly passed
if (-not $ConfigFile) {
    $currentScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $currentScriptDir) { $currentScriptDir = (Get-Location).Path }
    $ConfigFile = Join-Path (Join-Path $currentScriptDir "config") "profiles.json"
}

# Run as standard user without requiring or prompting for UAC elevation on launch.
# Elevation is only requested on-demand if the user tests raw PnP toggles in the USB tab.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Function to capture active DPI scaling percentages from connected displays
function Get-CurrentDisplayScales {
    param([string]$AppRoot)
    $setDpiExe = Join-Path $AppRoot "bin\SetDpi.exe"
    $scales = [ordered]@{}
    if (Test-Path -LiteralPath $setDpiExe) {
        for ($i = 1; $i -le 10; $i++) {
            $val = (& $setDpiExe value $i 2>&1) -join ""
            if ($val -match '^\d+$') {
                $scales["$i"] = [int]$val
            } else {
                break
            }
        }
    }
    return $scales
}

# Core Audio Policy Client for Instant Audio Detection and Switching
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig
{
    int GetMixFormat(string pszDeviceName, IntPtr ppFormat);
    int GetDeviceFormat(string pszDeviceName, int bDefault, IntPtr ppFormat);
    int ResetDeviceFormat(string pszDeviceName);
    int SetDeviceFormat(string pszDeviceName, IntPtr pEndpointFormat, IntPtr mixFormat);
    int GetProcessingPeriod(string pszDeviceName, int bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
    int SetProcessingPeriod(string pszDeviceName, IntPtr pmftPeriod);
    int GetShareMode(string pszDeviceName, IntPtr pMode);
    int SetShareMode(string pszDeviceName, IntPtr pMode);
    int GetPropertyValue(string pszDeviceName, int bStore, IntPtr key, IntPtr pv);
    int SetPropertyValue(string pszDeviceName, int bStore, IntPtr key, IntPtr pv);
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int role);
    int SetEndpointVisibility(string pszDeviceName, int bVisible);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    int GetDevice(string pwstrId, out IMMDevice ppDevice);
    int RegisterEndpointNotificationCallback(IntPtr pClient);
    int UnregisterEndpointNotificationCallback(IntPtr pClient);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice
{
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
    int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    int GetState(out int pdwState);
}

[ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
public class PolicyConfigClient {}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject {}

public static class AudioController
{
    public static int SetDefault(string deviceId)
    {
        try {
            var client = (IPolicyConfig)(new PolicyConfigClient());
            client.SetDefaultEndpoint(deviceId, 0); // eConsole
            client.SetDefaultEndpoint(deviceId, 1); // eMultimedia
            client.SetDefaultEndpoint(deviceId, 2); // eCommunications
            return 0;
        } catch {
            return -1;
        }
    }

    public static string GetCurrentDefaultId()
    {
        try {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            int hr = enumerator.GetDefaultAudioEndpoint(0, 0, out dev);
            if (hr != 0 || dev == null) return null;
            string id;
            dev.GetId(out id);
            return id;
        } catch {
            return null;
        }
    }
}

[ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
public class DesktopWallpaperClass {}

[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDesktopWallpaper
{
    [PreserveSig] int SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [PreserveSig] int GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] out string wallpaper);
    [PreserveSig] int GetMonitorDevicePathAt(uint monitorIndex, [MarshalAs(UnmanagedType.LPWStr)] out string monitorID);
    [PreserveSig] int GetMonitorDevicePathCount(out uint count);
    [PreserveSig] int GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out RECT displayRect);
    [PreserveSig] int SetBackgroundColor(uint color);
    [PreserveSig] int GetBackgroundColor(out uint color);
    [PreserveSig] int SetPosition(int position);
    [PreserveSig] int GetPosition(out int position);
    [PreserveSig] int SetSlideshow(IntPtr items);
    [PreserveSig] int GetSlideshow(out IntPtr items);
    [PreserveSig] int AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
    [PreserveSig] int GetStatus(out int state);
    [PreserveSig] int Enable(bool enable);
}

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public class MonitorWallpaperItem
{
    public uint Index;
    public string Path;
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
    public string CurrentWallpaper;
}

public static class DesktopWallpaperNative
{
    public static List<MonitorWallpaperItem> GetActiveMonitors()
    {
        var list = new List<MonitorWallpaperItem>();
        try {
            var dw = (IDesktopWallpaper)new DesktopWallpaperClass();
            uint count = 0;
            if (dw.GetMonitorDevicePathCount(out count) == 0) {
                for (uint i = 0; i < count; i++) {
                    string path;
                    if (dw.GetMonitorDevicePathAt(i, out path) == 0) {
                        RECT r;
                        int hrRect = dw.GetMonitorRECT(path, out r);
                        if (hrRect == 0) {
                            string curWall = "";
                            dw.GetWallpaper(path, out curWall);
                            list.Add(new MonitorWallpaperItem {
                                Index = i,
                                Path = path,
                                Left = r.Left,
                                Top = r.Top,
                                Right = r.Right,
                                Bottom = r.Bottom,
                                CurrentWallpaper = curWall ?? ""
                            });
                        }
                    }
                }
            }
        } catch {}
        return list;
    }

    public static int ApplyWallpaper(string monitorId, string wallpaperPath, int position)
    {
        try {
            var dw = (IDesktopWallpaper)new DesktopWallpaperClass();
            if (position >= 0 && position <= 5) {
                dw.SetPosition(position);
            }
            return dw.SetWallpaper(string.IsNullOrEmpty(monitorId) ? null : monitorId, wallpaperPath ?? "");
        } catch {
            return -1;
        }
    }
}
"@ -ErrorAction SilentlyContinue

function Get-ActiveAudioEndpoints {
    $results = @()
    try {
        $renderKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render" -ErrorAction SilentlyContinue
        foreach ($k in $renderKeys) {
            $state = (Get-ItemProperty $k.PSPath).DeviceState
            if ($state -eq 1) { # Active
                $props = Get-ItemProperty (Join-Path $k.PSPath "Properties") -ErrorAction SilentlyContinue
                $devName = $props."{a45c254e-df1c-4efd-8020-67d146a850e0},2"
                $adapter = $props."{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
                if ($devName) {
                    $results += [PSCustomObject]@{
                        Id      = $k.PSChildName
                        Name    = $devName
                        Adapter = $adapter
                        Display = if ($adapter) { "$devName ($adapter)" } else { $devName }
                    }
                }
            }
        }
    } catch {}
    return $results
}

function Get-LiveDefaultAudioName {
    try {
        $fullId = [AudioController]::GetCurrentDefaultId()
        if ($fullId) {
            $guid = $fullId -replace '^.*\{', '{'
            $activeList = Get-ActiveAudioEndpoints
            $matched = $activeList | Where-Object { $_.Id -eq $guid } | Select-Object -First 1
            if ($matched) { return $matched.Display }
        }
    } catch {}
    return ""
}

function Get-LiveConfig {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $null }
    $raw = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Save-LiveConfig ($cfg) {
    $json = $cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigFile, $json, [System.Text.Encoding]::UTF8)
}

$config = Get-LiveConfig
if (-not $config) {
    [System.Windows.Forms.MessageBox]::Show("Could not find configuration file: $ConfigFile", "Error", "OK", "Error")
    exit 1
}

$scriptDir = if ($config.ProfilesDir) { $config.ProfilesDir } else { Split-Path (Split-Path $ConfigFile) }
$configDir = Split-Path $ConfigFile

# Main Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "DeskShift - Display Switcher, Hardware & Web Remote Manager"
$form.Size = New-Object System.Drawing.Size(1200, 750)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

# Header
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 70
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)

$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = "DeskShift • Hardware & Web Remote Manager"
$headerTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13.0, [System.Drawing.FontStyle]::Bold)
$headerTitle.ForeColor = [System.Drawing.Color]::White
$headerTitle.Location = New-Object System.Drawing.Point(20, 12)
$headerTitle.AutoSize = $true
$headerPanel.Controls.Add($headerTitle)

$headerSubtitle = New-Object System.Windows.Forms.Label
$headerSubtitle.Text = "Configure USB power states, Smart Plugs (Kasa / Tapo), and iPhone Web Remote access."
$headerSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
$headerSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$headerSubtitle.Location = New-Object System.Drawing.Point(21, 38)
$headerSubtitle.AutoSize = $true
$headerPanel.Controls.Add($headerSubtitle)

$form.Controls.Add($headerPanel)

# Tab Control
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 85)
$tabs.Size = New-Object System.Drawing.Size(1145, 560)

# ==============================================================================
# TAB 1: Profile Assignment Matrix (Devices & Plugs downwards as Rows, Profiles as Columns)
# ==============================================================================
$tabMatrix = New-Object System.Windows.Forms.TabPage("Profile Assignment Matrix")
$tabMatrix.BackColor = [System.Drawing.Color]::White

# Top toolbar panel for profile creation and display capture
$matrixTopBar = New-Object System.Windows.Forms.Panel
$matrixTopBar.Dock = "Top"
$matrixTopBar.Height = 48
$matrixTopBar.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)

$lblProfileSelect = New-Object System.Windows.Forms.Label
$lblProfileSelect.Text = "Profile:"
$lblProfileSelect.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$lblProfileSelect.Location = New-Object System.Drawing.Point(8, 14)
$lblProfileSelect.AutoSize = $true
$matrixTopBar.Controls.Add($lblProfileSelect)

$cmbProfiles = New-Object System.Windows.Forms.ComboBox
$cmbProfiles.DropDownStyle = "DropDownList"
$cmbProfiles.Location = New-Object System.Drawing.Point(58, 11)
$cmbProfiles.Size = New-Object System.Drawing.Size(210, 25)
$matrixTopBar.Controls.Add($cmbProfiles)

$btnCaptureLayout = New-Object System.Windows.Forms.Button
$btnCaptureLayout.Text = "Capture Layout"
$btnCaptureLayout.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnCaptureLayout.Location = New-Object System.Drawing.Point(275, 9)
$btnCaptureLayout.Size = New-Object System.Drawing.Size(105, 30)
$btnCaptureLayout.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
$btnCaptureLayout.ForeColor = [System.Drawing.Color]::White
$btnCaptureLayout.FlatStyle = "Flat"
$btnCaptureLayout.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnCaptureLayout)

$btnRenameProfile = New-Object System.Windows.Forms.Button
$btnRenameProfile.Text = "Rename"
$btnRenameProfile.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnRenameProfile.Location = New-Object System.Drawing.Point(388, 9)
$btnRenameProfile.Size = New-Object System.Drawing.Size(75, 30)
$btnRenameProfile.BackColor = [System.Drawing.Color]::FromArgb(79, 70, 229)
$btnRenameProfile.ForeColor = [System.Drawing.Color]::White
$btnRenameProfile.FlatStyle = "Flat"
$btnRenameProfile.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnRenameProfile)

$btnNewProfile = New-Object System.Windows.Forms.Button
$btnNewProfile.Text = "+ New Profile"
$btnNewProfile.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnNewProfile.Location = New-Object System.Drawing.Point(471, 9)
$btnNewProfile.Size = New-Object System.Drawing.Size(100, 30)
$btnNewProfile.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$btnNewProfile.ForeColor = [System.Drawing.Color]::White
$btnNewProfile.FlatStyle = "Flat"
$btnNewProfile.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnNewProfile)

$btnConfigToggle = New-Object System.Windows.Forms.Button
$btnConfigToggle.Text = "Toggle Cycle"
$btnConfigToggle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnConfigToggle.Location = New-Object System.Drawing.Point(579, 9)
$btnConfigToggle.Size = New-Object System.Drawing.Size(100, 30)
$btnConfigToggle.BackColor = [System.Drawing.Color]::FromArgb(139, 92, 246)
$btnConfigToggle.ForeColor = [System.Drawing.Color]::White
$btnConfigToggle.FlatStyle = "Flat"
$btnConfigToggle.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnConfigToggle)

$btnManageOrder = New-Object System.Windows.Forms.Button
$btnManageOrder.Text = "Menu & Lines"
$btnManageOrder.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnManageOrder.Location = New-Object System.Drawing.Point(687, 9)
$btnManageOrder.Size = New-Object System.Drawing.Size(105, 30)
$btnManageOrder.BackColor = [System.Drawing.Color]::FromArgb(14, 116, 144)
$btnManageOrder.ForeColor = [System.Drawing.Color]::White
$btnManageOrder.FlatStyle = "Flat"
$btnManageOrder.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnManageOrder)

$btnAudioSelect = New-Object System.Windows.Forms.Button
$btnAudioSelect.Text = "Audio Device"
$btnAudioSelect.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnAudioSelect.Location = New-Object System.Drawing.Point(800, 9)
$btnAudioSelect.Size = New-Object System.Drawing.Size(95, 30)
$btnAudioSelect.BackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
$btnAudioSelect.ForeColor = [System.Drawing.Color]::White
$btnAudioSelect.FlatStyle = "Flat"
$btnAudioSelect.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnAudioSelect)

$btnAppSelect = New-Object System.Windows.Forms.Button
$btnAppSelect.Text = "Launch App"
$btnAppSelect.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnAppSelect.Location = New-Object System.Drawing.Point(900, 9)
$btnAppSelect.Size = New-Object System.Drawing.Size(95, 30)
$btnAppSelect.BackColor = [System.Drawing.Color]::FromArgb(13, 148, 136)
$btnAppSelect.ForeColor = [System.Drawing.Color]::White
$btnAppSelect.FlatStyle = "Flat"
$btnAppSelect.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnAppSelect)

$btnWallpapers = New-Object System.Windows.Forms.Button
$btnWallpapers.Text = "Wallpapers"
$btnWallpapers.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$btnWallpapers.Location = New-Object System.Drawing.Point(1000, 9)
$btnWallpapers.Size = New-Object System.Drawing.Size(95, 30)
$btnWallpapers.BackColor = [System.Drawing.Color]::FromArgb(225, 29, 72)
$btnWallpapers.ForeColor = [System.Drawing.Color]::White
$btnWallpapers.FlatStyle = "Flat"
$btnWallpapers.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnWallpapers)

$btnDeleteProfile = New-Object System.Windows.Forms.Button
$btnDeleteProfile.Text = "Delete"
$btnDeleteProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
$btnDeleteProfile.Location = New-Object System.Drawing.Point(1100, 9)
$btnDeleteProfile.Size = New-Object System.Drawing.Size(65, 30)
$btnDeleteProfile.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
$btnDeleteProfile.ForeColor = [System.Drawing.Color]::White
$btnDeleteProfile.FlatStyle = "Flat"
$btnDeleteProfile.FlatAppearance.BorderSize = 0
$matrixTopBar.Controls.Add($btnDeleteProfile)

$matrixGrid = New-Object System.Windows.Forms.DataGridView
$matrixGrid.Dock = "Fill"
$matrixGrid.AllowUserToAddRows = $false
$matrixGrid.AllowUserToDeleteRows = $false
$matrixGrid.RowHeadersVisible = $false
$matrixGrid.AutoSizeColumnsMode = "AllCells"
$matrixGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::EnableResizing
$matrixGrid.ColumnHeadersHeight = 36
$matrixGrid.EnableHeadersVisualStyles = $false
$matrixGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$matrixGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$matrixGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$matrixGrid.BackgroundColor = [System.Drawing.Color]::White
$matrixGrid.BorderStyle = "None"
$matrixGrid.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
$matrixGrid.SelectionMode = "CellSelect"

# Add DataGridView FIRST so it fills below the Dock=Top panel
$tabMatrix.Controls.Add($matrixGrid)
$tabMatrix.Controls.Add($matrixTopBar)
$tabs.TabPages.Add($tabMatrix)

# ==============================================================================
# TAB 2: Dynamic Smart Plugs
# ==============================================================================
$tabPlugs = New-Object System.Windows.Forms.TabPage("Smart Plugs")
$tabPlugs.BackColor = [System.Drawing.Color]::White

# Plugs ListView
$plugListView = New-Object System.Windows.Forms.ListView
$plugListView.Location = New-Object System.Drawing.Point(15, 15)
$plugListView.Size = New-Object System.Drawing.Size(870, 200)
$plugListView.View = "Details"
$plugListView.FullRowSelect = $true
$plugListView.GridLines = $true
$plugListView.Columns.Add("Friendly Name", 200) | Out-Null
$plugListView.Columns.Add("Plug Key", 140) | Out-Null
$plugListView.Columns.Add("Type / Protocol", 130) | Out-Null
$plugListView.Columns.Add("IP Address", 140) | Out-Null
$plugListView.Columns.Add("Auth Required", 130) | Out-Null
$tabPlugs.Controls.Add($plugListView)

# Plug Quick Actions (Test ON / OFF / Delete)
$btnTestPlugOn = New-Object System.Windows.Forms.Button
$btnTestPlugOn.Text = "Test ON"
$btnTestPlugOn.Location = New-Object System.Drawing.Point(15, 225)
$btnTestPlugOn.Size = New-Object System.Drawing.Size(100, 32)
$btnTestPlugOn.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$btnTestPlugOn.ForeColor = [System.Drawing.Color]::White
$btnTestPlugOn.FlatStyle = "Flat"

$btnTestPlugOff = New-Object System.Windows.Forms.Button
$btnTestPlugOff.Text = "Test OFF"
$btnTestPlugOff.Location = New-Object System.Drawing.Point(125, 225)
$btnTestPlugOff.Size = New-Object System.Drawing.Size(100, 32)
$btnTestPlugOff.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
$btnTestPlugOff.ForeColor = [System.Drawing.Color]::White
$btnTestPlugOff.FlatStyle = "Flat"

$btnDeletePlug = New-Object System.Windows.Forms.Button
$btnDeletePlug.Text = "Delete Plug"
$btnDeletePlug.Location = New-Object System.Drawing.Point(235, 225)
$btnDeletePlug.Size = New-Object System.Drawing.Size(110, 32)
$btnDeletePlug.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$btnDeletePlug.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$btnDeletePlug.FlatStyle = "Flat"

$tabPlugs.Controls.Add($btnTestPlugOn)
$tabPlugs.Controls.Add($btnTestPlugOff)
$tabPlugs.Controls.Add($btnDeletePlug)

# Add / Edit Plug GroupBox
$addPlugBox = New-Object System.Windows.Forms.GroupBox
$addPlugBox.Text = "Add / Update Smart Plug or Power Device"
$addPlugBox.Location = New-Object System.Drawing.Point(15, 265)
$addPlugBox.Size = New-Object System.Drawing.Size(1000, 130)

$lblPKey = New-Object System.Windows.Forms.Label
$lblPKey.Text = "Plug Key (ID):"
$lblPKey.Location = New-Object System.Drawing.Point(15, 24)
$lblPKey.AutoSize = $true
$addPlugBox.Controls.Add($lblPKey)

$txtPlugKey = New-Object System.Windows.Forms.TextBox
$txtPlugKey.Location = New-Object System.Drawing.Point(15, 44)
$txtPlugKey.Size = New-Object System.Drawing.Size(130, 26)
$addPlugBox.Controls.Add($txtPlugKey)

$lblPName = New-Object System.Windows.Forms.Label
$lblPName.Text = "Friendly Name:"
$lblPName.Location = New-Object System.Drawing.Point(155, 24)
$lblPName.AutoSize = $true
$addPlugBox.Controls.Add($lblPName)

$txtPlugName = New-Object System.Windows.Forms.TextBox
$txtPlugName.Location = New-Object System.Drawing.Point(155, 44)
$txtPlugName.Size = New-Object System.Drawing.Size(180, 26)
$addPlugBox.Controls.Add($txtPlugName)

$lblPType = New-Object System.Windows.Forms.Label
$lblPType.Text = "Plug Type:"
$lblPType.Location = New-Object System.Drawing.Point(345, 24)
$lblPType.AutoSize = $true
$addPlugBox.Controls.Add($lblPType)

$cmbPlugType = New-Object System.Windows.Forms.ComboBox
$cmbPlugType.DropDownStyle = "DropDownList"
$cmbPlugType.Items.AddRange(@(
    "Kasa (Zero Login - Port 9999)",
    "Tapo (KLAP / SPAKE2+)",
    "Home Assistant (REST Entity)",
    "HTTP Webhook (Shelly / Tasmota)",
    "Custom Shell Command"
))
$cmbPlugType.SelectedIndex = 0
$cmbPlugType.Location = New-Object System.Drawing.Point(345, 44)
$cmbPlugType.Size = New-Object System.Drawing.Size(200, 26)
$addPlugBox.Controls.Add($cmbPlugType)

$lblPIp = New-Object System.Windows.Forms.Label
$lblPIp.Text = "IP Address / Target:"
$lblPIp.Location = New-Object System.Drawing.Point(555, 24)
$lblPIp.AutoSize = $true
$addPlugBox.Controls.Add($lblPIp)

$txtPlugIp = New-Object System.Windows.Forms.TextBox
$txtPlugIp.Location = New-Object System.Drawing.Point(555, 44)
$txtPlugIp.Size = New-Object System.Drawing.Size(200, 26)
$addPlugBox.Controls.Add($txtPlugIp)

$lblPOff = New-Object System.Windows.Forms.Label
$lblPOff.Text = "OFF Command / URL (Optional):"
$lblPOff.Location = New-Object System.Drawing.Point(765, 24)
$lblPOff.AutoSize = $true
$lblPOff.Visible = $false
$addPlugBox.Controls.Add($lblPOff)

$txtPlugOff = New-Object System.Windows.Forms.TextBox
$txtPlugOff.Location = New-Object System.Drawing.Point(765, 44)
$txtPlugOff.Size = New-Object System.Drawing.Size(220, 26)
$txtPlugOff.Visible = $false
$addPlugBox.Controls.Add($txtPlugOff)

$btnSavePlug = New-Object System.Windows.Forms.Button
$btnSavePlug.Text = "Add / Update"
$btnSavePlug.Location = New-Object System.Drawing.Point(875, 80)
$btnSavePlug.Size = New-Object System.Drawing.Size(110, 32)
$btnSavePlug.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnSavePlug.ForeColor = [System.Drawing.Color]::White
$btnSavePlug.FlatStyle = "Flat"
$addPlugBox.Controls.Add($btnSavePlug)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Kasa/Tapo: enter local IP | Home Assistant: entity ID (e.g. switch.rig) | Webhook/Command: single action with {state} or enter explicit ON and OFF actions."
$lblHint.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblHint.Location = New-Object System.Drawing.Point(15, 85)
$lblHint.AutoSize = $true
$addPlugBox.Controls.Add($lblHint)

$cmbPlugType.add_SelectedIndexChanged({
    switch ($cmbPlugType.SelectedIndex) {
        0 { # Kasa
            $lblPIp.Text = "IP Address:"
            $lblPOff.Visible = $false
            $txtPlugOff.Visible = $false
            $txtPlugIp.Size = New-Object System.Drawing.Size(300, 26)
        }
        1 { # Tapo
            $lblPIp.Text = "IP Address:"
            $lblPOff.Visible = $false
            $txtPlugOff.Visible = $false
            $txtPlugIp.Size = New-Object System.Drawing.Size(300, 26)
        }
        2 { # Home Assistant
            $lblPIp.Text = "Entity ID (e.g. switch.rig):"
            $lblPOff.Visible = $false
            $txtPlugOff.Visible = $false
            $txtPlugIp.Size = New-Object System.Drawing.Size(300, 26)
        }
        3 { # Webhook
            $lblPIp.Text = "ON URL (or URL with {state}):"
            $lblPOff.Text = "OFF URL (Optional):"
            $lblPOff.Visible = $true
            $txtPlugOff.Visible = $true
            $txtPlugIp.Size = New-Object System.Drawing.Size(200, 26)
        }
        4 { # Custom Command
            $lblPIp.Text = "ON Command (or with {state}):"
            $lblPOff.Text = "OFF Command (Optional):"
            $lblPOff.Visible = $true
            $txtPlugOff.Visible = $true
            $txtPlugIp.Size = New-Object System.Drawing.Size(200, 26)
        }
    }
})

$tabPlugs.Controls.Add($addPlugBox)

# Tapo Credentials GroupBox
$credBox = New-Object System.Windows.Forms.GroupBox
$credBox.Text = "Tapo Account Authentication (Only required for Tapo plugs; Kasa plugs use zero-login)"
$credBox.Location = New-Object System.Drawing.Point(15, 395)
$credBox.Size = New-Object System.Drawing.Size(870, 95)

$lblEmail = New-Object System.Windows.Forms.Label
$lblEmail.Text = "Tapo Email:"
$lblEmail.Location = New-Object System.Drawing.Point(15, 32)
$lblEmail.AutoSize = $true
$credBox.Controls.Add($lblEmail)

$txtEmail = New-Object System.Windows.Forms.TextBox
$txtEmail.Location = New-Object System.Drawing.Point(100, 28)
$txtEmail.Size = New-Object System.Drawing.Size(260, 26)
$credBox.Controls.Add($txtEmail)

$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = "Password:"
$lblPass.Location = New-Object System.Drawing.Point(385, 32)
$lblPass.AutoSize = $true
$credBox.Controls.Add($lblPass)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.UseSystemPasswordChar = $true
$txtPass.Location = New-Object System.Drawing.Point(460, 28)
$txtPass.Size = New-Object System.Drawing.Size(260, 26)
$credBox.Controls.Add($txtPass)

$tabPlugs.Controls.Add($credBox)
$tabs.TabPages.Add($tabPlugs)

# ==============================================================================
# TAB 3: Managed USB Devices
# ==============================================================================
$tabDevices = New-Object System.Windows.Forms.TabPage("Managed USB Devices")
$tabDevices.BackColor = [System.Drawing.Color]::White

$deviceListView = New-Object System.Windows.Forms.ListView
$deviceListView.Location = New-Object System.Drawing.Point(15, 15)
$deviceListView.Size = New-Object System.Drawing.Size(870, 260)
$deviceListView.View = "Details"
$deviceListView.FullRowSelect = $true
$deviceListView.GridLines = $true
$deviceListView.Columns.Add("Friendly Name", 220) | Out-Null
$deviceListView.Columns.Add("Key", 110) | Out-Null
$deviceListView.Columns.Add("Live Status", 130) | Out-Null
$deviceListView.Columns.Add("Instance ID", 360) | Out-Null
$tabDevices.Controls.Add($deviceListView)

# Test Buttons Panel
$testOnBtn = New-Object System.Windows.Forms.Button
$testOnBtn.Text = "Turn ON Selected"
$testOnBtn.Location = New-Object System.Drawing.Point(15, 285)
$testOnBtn.Size = New-Object System.Drawing.Size(140, 32)
$testOnBtn.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$testOnBtn.ForeColor = [System.Drawing.Color]::White
$testOnBtn.FlatStyle = "Flat"

$testOffBtn = New-Object System.Windows.Forms.Button
$testOffBtn.Text = "Turn OFF Selected"
$testOffBtn.Location = New-Object System.Drawing.Point(165, 285)
$testOffBtn.Size = New-Object System.Drawing.Size(140, 32)
$testOffBtn.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
$testOffBtn.ForeColor = [System.Drawing.Color]::White
$testOffBtn.FlatStyle = "Flat"

$renameDevBtn = New-Object System.Windows.Forms.Button
$renameDevBtn.Text = "Rename Selected"
$renameDevBtn.Location = New-Object System.Drawing.Point(315, 285)
$renameDevBtn.Size = New-Object System.Drawing.Size(140, 32)
$renameDevBtn.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$renameDevBtn.ForeColor = [System.Drawing.Color]::White
$renameDevBtn.FlatStyle = "Flat"

$removeDevBtn = New-Object System.Windows.Forms.Button
$removeDevBtn.Text = "Remove from Management"
$removeDevBtn.Location = New-Object System.Drawing.Point(465, 285)
$removeDevBtn.Size = New-Object System.Drawing.Size(190, 32)
$removeDevBtn.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$removeDevBtn.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$removeDevBtn.FlatStyle = "Flat"

$tabDevices.Controls.Add($testOnBtn)
$tabDevices.Controls.Add($testOffBtn)
$tabDevices.Controls.Add($renameDevBtn)
$tabDevices.Controls.Add($removeDevBtn)

# Add New USB Device Section
$addBox = New-Object System.Windows.Forms.GroupBox
$addBox.Text = "Add Connected USB Device"
$addBox.Location = New-Object System.Drawing.Point(15, 330)
$addBox.Size = New-Object System.Drawing.Size(950, 110)

$lblAddDevSelect = New-Object System.Windows.Forms.Label
$lblAddDevSelect.Text = "Connected Device:"
$lblAddDevSelect.Location = New-Object System.Drawing.Point(15, 22)
$lblAddDevSelect.AutoSize = $true
$addBox.Controls.Add($lblAddDevSelect)

$addCombo = New-Object System.Windows.Forms.ComboBox
$addCombo.DropDownStyle = "DropDownList"
$addCombo.Location = New-Object System.Drawing.Point(15, 45)
$addCombo.Size = New-Object System.Drawing.Size(420, 28)
$addBox.Controls.Add($addCombo)

$lblAddFriendly = New-Object System.Windows.Forms.Label
$lblAddFriendly.Text = "Friendly Name (Grid Row):"
$lblAddFriendly.Location = New-Object System.Drawing.Point(445, 22)
$lblAddFriendly.AutoSize = $true
$addBox.Controls.Add($lblAddFriendly)

$addNameBox = New-Object System.Windows.Forms.TextBox
$addNameBox.Location = New-Object System.Drawing.Point(445, 45)
$addNameBox.Size = New-Object System.Drawing.Size(200, 26)
$addBox.Controls.Add($addNameBox)

$lblAddKey = New-Object System.Windows.Forms.Label
$lblAddKey.Text = "Config Key (JSON ID):"
$lblAddKey.Location = New-Object System.Drawing.Point(655, 22)
$lblAddKey.AutoSize = $true
$addBox.Controls.Add($lblAddKey)

$addKeyBox = New-Object System.Windows.Forms.TextBox
$addKeyBox.Location = New-Object System.Drawing.Point(655, 45)
$addKeyBox.Size = New-Object System.Drawing.Size(150, 26)
$addBox.Controls.Add($addKeyBox)

$addBtn = New-Object System.Windows.Forms.Button
$addBtn.Text = "+ Add Device"
$addBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$addBtn.Location = New-Object System.Drawing.Point(815, 42)
$addBtn.Size = New-Object System.Drawing.Size(120, 31)
$addBtn.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$addBtn.ForeColor = [System.Drawing.Color]::White
$addBtn.FlatStyle = "Flat"
$addBox.Controls.Add($addBtn)

$lblKeyHint = New-Object System.Windows.Forms.Label
$lblKeyHint.Text = "The Config Key is the unique variable identifier in profiles.json (alphanumeric, no spaces). It auto-fills from the name or you can type your own."
$lblKeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblKeyHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.25)
$lblKeyHint.Location = New-Object System.Drawing.Point(15, 80)
$lblKeyHint.AutoSize = $true
$addBox.Controls.Add($lblKeyHint)

$tabDevices.Controls.Add($addBox)

$tabs.TabPages.Add($tabDevices)

# ==============================================================================
# TAB 4: Mobile Web Remote & iOS Shortcuts
# ==============================================================================
$tabWeb = New-Object System.Windows.Forms.TabPage("Mobile Web & iOS Shortcuts")
$tabWeb.BackColor = [System.Drawing.Color]::White

$webBox = New-Object System.Windows.Forms.GroupBox
$webBox.Text = "Mobile Web Remote Service & Dashboard Customization"
$webBox.Location = New-Object System.Drawing.Point(15, 15)
$webBox.Size = New-Object System.Drawing.Size(890, 520)

$chkEnableWebRemote = New-Object System.Windows.Forms.CheckBox
$chkEnableWebRemote.Text = "Enable Background Mobile Web Remote Server (HTTPS / Local Network)"
$chkEnableWebRemote.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10.0, [System.Drawing.FontStyle]::Bold)
$chkEnableWebRemote.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$chkEnableWebRemote.Location = New-Object System.Drawing.Point(20, 24)
$chkEnableWebRemote.Size = New-Object System.Drawing.Size(600, 26)
$chkEnableWebRemote.Checked = if ($config.WebRemote -and ($null -ne $config.WebRemote.Enabled)) { [bool]$config.WebRemote.Enabled } else { $true }
$webBox.Controls.Add($chkEnableWebRemote)

$panelWebOptions = New-Object System.Windows.Forms.Panel
$panelWebOptions.Location = New-Object System.Drawing.Point(15, 55)
$panelWebOptions.Size = New-Object System.Drawing.Size(860, 455)
$panelWebOptions.Enabled = $chkEnableWebRemote.Checked
$webBox.Controls.Add($panelWebOptions)

$chkEnableWebRemote.add_CheckedChanged({
    $panelWebOptions.Enabled = $chkEnableWebRemote.Checked
})

$lblDomainEdit = New-Object System.Windows.Forms.Label
$lblDomainEdit.Text = "Domain / Hostname:"
$lblDomainEdit.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$lblDomainEdit.Location = New-Object System.Drawing.Point(5, 5)
$lblDomainEdit.AutoSize = $true
$panelWebOptions.Controls.Add($lblDomainEdit)

$txtWebDomain = New-Object System.Windows.Forms.TextBox
$txtWebDomain.Location = New-Object System.Drawing.Point(5, 26)
$txtWebDomain.Size = New-Object System.Drawing.Size(260, 25)
$txtWebDomain.Text = if ($config.WebRemote -and $config.WebRemote.Domain) { $config.WebRemote.Domain } else { "screen.jasonpatel.co.uk" }
$panelWebOptions.Controls.Add($txtWebDomain)

$lblPortEdit = New-Object System.Windows.Forms.Label
$lblPortEdit.Text = "HTTP Port:"
$lblPortEdit.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$lblPortEdit.Location = New-Object System.Drawing.Point(280, 5)
$lblPortEdit.AutoSize = $true
$panelWebOptions.Controls.Add($lblPortEdit)

$numWebPort = New-Object System.Windows.Forms.NumericUpDown
$numWebPort.Minimum = 80
$numWebPort.Maximum = 65535
$numWebPort.Value = if ($config.WebRemote -and $config.WebRemote.Port) { $config.WebRemote.Port } else { 8088 }
$numWebPort.Location = New-Object System.Drawing.Point(280, 26)
$numWebPort.Size = New-Object System.Drawing.Size(80, 25)
$panelWebOptions.Controls.Add($numWebPort)

$lblUrl1 = New-Object System.Windows.Forms.Label
$lblUrl1.Text = "HTTPS Link:"
$lblUrl1.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$lblUrl1.Location = New-Object System.Drawing.Point(380, 5)
$lblUrl1.AutoSize = $true
$panelWebOptions.Controls.Add($lblUrl1)

$lnkDomain = New-Object System.Windows.Forms.LinkLabel
$lnkDomain.Text = "https://" + $txtWebDomain.Text.Trim()
$lnkDomain.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lnkDomain.Location = New-Object System.Drawing.Point(380, 27)
$lnkDomain.AutoSize = $true
$lnkDomain.add_LinkClicked({ [System.Diagnostics.Process]::Start($this.Text) })
$panelWebOptions.Controls.Add($lnkDomain)

# Web Remote Profile Button Customizer Table
$lblWebGrid = New-Object System.Windows.Forms.Label
$lblWebGrid.Text = "Customize Web Remote Buttons (Toggle Visibility, Icon Emoji & Color):"
$lblWebGrid.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
$lblWebGrid.Location = New-Object System.Drawing.Point(5, 62)
$lblWebGrid.AutoSize = $true
$panelWebOptions.Controls.Add($lblWebGrid)

$webGrid = New-Object System.Windows.Forms.DataGridView
$webGrid.Location = New-Object System.Drawing.Point(5, 85)
$webGrid.Size = New-Object System.Drawing.Size(850, 195)
$webGrid.AllowUserToAddRows = $false
$webGrid.AllowUserToDeleteRows = $false
$webGrid.RowHeadersVisible = $false
$webGrid.AutoSizeColumnsMode = "Fill"
$webGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::EnableResizing
$webGrid.ColumnHeadersHeight = 30
$webGrid.EnableHeadersVisualStyles = $false
$webGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$webGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$webGrid.BackgroundColor = [System.Drawing.Color]::White
$webGrid.BorderStyle = "FixedSingle"
$webGrid.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

$colVisible = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colVisible.HeaderText = "Show on Phone"
$colVisible.Name = "WebVisible"
$colVisible.Width = 110
$webGrid.Columns.Add($colVisible) | Out-Null

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = "Profile / Button Title"
$colName.Name = "ProfileTitle"
$colName.ReadOnly = $true
$colName.Width = 260
$webGrid.Columns.Add($colName) | Out-Null

$colIcon = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colIcon.HeaderText = "Icon (Emoji)"
$colIcon.Name = "WebIcon"
$colIcon.Width = 100
$webGrid.Columns.Add($colIcon) | Out-Null

$colColor = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colColor.HeaderText = "Accent Color (Hex e.g. #3b82f6)"
$colColor.Name = "WebColor"
$colColor.Width = 180
$webGrid.Columns.Add($colColor) | Out-Null

$panelWebOptions.Controls.Add($webGrid)

# Instructions Box & SSL Management Bar
$btnGenCert = New-Object System.Windows.Forms.Button
$btnGenCert.Text = "Regenerate Self-Signed SSL Cert"
$btnGenCert.Location = New-Object System.Drawing.Point(5, 288)
$btnGenCert.Size = New-Object System.Drawing.Size(220, 28)
$btnGenCert.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnGenCert.ForeColor = [System.Drawing.Color]::White
$btnGenCert.FlatStyle = "Flat"
$panelWebOptions.Controls.Add($btnGenCert)

$btnImportCert = New-Object System.Windows.Forms.Button
$btnImportCert.Text = "Import Existing Cert (.pfx / .pem)"
$btnImportCert.Location = New-Object System.Drawing.Point(235, 288)
$btnImportCert.Size = New-Object System.Drawing.Size(220, 28)
$btnImportCert.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$btnImportCert.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$btnImportCert.FlatStyle = "Flat"
$panelWebOptions.Controls.Add($btnImportCert)

$lblCertStatus = New-Object System.Windows.Forms.Label
$lblCertStatus.Location = New-Object System.Drawing.Point(465, 294)
$lblCertStatus.Size = New-Object System.Drawing.Size(390, 20)
$lblCertStatus.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$lblCertStatus.Text = "Detecting SSL certificate..."
$panelWebOptions.Controls.Add($lblCertStatus)

$btnGenCert.add_Click({
    $scriptDir = Split-Path $ConfigFile
    $appRoot = Split-Path $scriptDir
    $certScript = Join-Path $appRoot "scripts\cert-generator.js"
    $dom = $txtWebDomain.Text.Trim()

    if (-not (Test-Path -LiteralPath $certScript)) {
        [System.Windows.Forms.MessageBox]::Show("cert-generator.js not found in scripts\.", "Error", "OK", "Error")
        return
    }

    $resJson = & node "$certScript" gen "$dom"
    try {
        $res = $resJson | ConvertFrom-Json
        if ($res.success) {
            [System.Windows.Forms.MessageBox]::Show("SSL Certificate successfully generated for:`n" + ($res.san -join ", ") + "`n`nValid for 5 years. Restart Web Remote to apply.", "Certificate Generated", "OK", "Information")
            & $refreshCertInfo
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to generate certificate: $($res.error)", "Generation Failed", "OK", "Error")
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error executing cert generator: $_", "Error", "OK", "Error")
    }
})

$btnImportCert.add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select SSL Certificate (.pfx, .p12, .crt, .pem)"
    $dlg.Filter = "Certificate Files (*.pfx;*.p12;*.pem;*.crt)|*.pfx;*.p12;*.pem;*.crt|All Files (*.*)|*.*"
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $filePath = $dlg.FileName
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $scriptDir = Split-Path $ConfigFile
        $appRoot = Split-Path $scriptDir
        $certScript = Join-Path $appRoot "scripts\cert-generator.js"

        if ($ext -in @(".pfx", ".p12")) {
            $passForm = New-Object System.Windows.Forms.Form
            $passForm.Text = "PFX Password"
            $passForm.Size = New-Object System.Drawing.Size(340, 150)
            $passForm.StartPosition = "CenterParent"
            $passForm.FormBorderStyle = "FixedDialog"
            $passForm.MaximizeBox = $false
            $passForm.MinimizeBox = $false

            $lblP = New-Object System.Windows.Forms.Label
            $lblP.Text = "Enter password for this PFX (leave blank if none):"
            $lblP.Location = New-Object System.Drawing.Point(15, 15)
            $lblP.Size = New-Object System.Drawing.Size(300, 20)
            $passForm.Controls.Add($lblP)

            $txtP = New-Object System.Windows.Forms.TextBox
            $txtP.Location = New-Object System.Drawing.Point(15, 40)
            $txtP.Size = New-Object System.Drawing.Size(295, 25)
            $txtP.UseSystemPasswordChar = $true
            $passForm.Controls.Add($txtP)

            $btnPOk = New-Object System.Windows.Forms.Button
            $btnPOk.Text = "Import"
            $btnPOk.Location = New-Object System.Drawing.Point(135, 75)
            $btnPOk.Size = New-Object System.Drawing.Size(80, 28)
            $btnPOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $passForm.Controls.Add($btnPOk)
            $passForm.AcceptButton = $btnPOk

            $btnPCancel = New-Object System.Windows.Forms.Button
            $btnPCancel.Text = "Cancel"
            $btnPCancel.Location = New-Object System.Drawing.Point(225, 75)
            $btnPCancel.Size = New-Object System.Drawing.Size(80, 28)
            $btnPCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $passForm.Controls.Add($btnPCancel)

            if ($passForm.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $resJson = & node "$certScript" import "$filePath" "$($txtP.Text)"
                $res = $resJson | ConvertFrom-Json
                if ($res.success) {
                    [System.Windows.Forms.MessageBox]::Show("PFX Certificate & Private Key imported successfully!", "Imported", "OK", "Information")
                    & $refreshCertInfo
                } else {
                    [System.Windows.Forms.MessageBox]::Show("Import failed: $($res.error)", "Error", "OK", "Error")
                }
            }
        } else {
            # For PEM/CRT, also prompt for Key file
            $keyDlg = New-Object System.Windows.Forms.OpenFileDialog
            $keyDlg.Title = "Select Matching Private Key File (.key, .pem)"
            $keyDlg.Filter = "Key Files (*.key;*.pem)|*.key;*.pem|All Files (*.*)|*.*"
            if ($keyDlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $resJson = & node "$certScript" import "$filePath" "$($keyDlg.FileName)"
                $res = $resJson | ConvertFrom-Json
                if ($res.success) {
                    [System.Windows.Forms.MessageBox]::Show("Certificate & Key imported successfully!", "Imported", "OK", "Information")
                    & $refreshCertInfo
                } else {
                    [System.Windows.Forms.MessageBox]::Show("Import failed: $($res.error)", "Error", "OK", "Error")
                }
            }
        }
    }
})

$refreshCertInfo = {
    $scriptDir = Split-Path $ConfigFile
    $appRoot = Split-Path $scriptDir
    $certScript = Join-Path $appRoot "scripts\cert-generator.js"
    if (Test-Path -LiteralPath $certScript) {
        $infoJson = & node "$certScript" info
        try {
            $info = $infoJson | ConvertFrom-Json
            if ($info.exists -and -not $info.error) {
                $lblCertStatus.Text = "SSL Active: " + $info.san
                $lblCertStatus.ForeColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
            } else {
                $lblCertStatus.Text = "No SSL cert installed (HTTPS disabled)"
                $lblCertStatus.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
            }
        } catch {
            $lblCertStatus.Text = "Could not check SSL status."
        }
    }
}

# Instructions Box
$txtInstructions = New-Object System.Windows.Forms.TextBox
$txtInstructions.Multiline = $true
$txtInstructions.ReadOnly = $true
$txtInstructions.ScrollBars = "Vertical"
$txtInstructions.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$txtInstructions.Location = New-Object System.Drawing.Point(5, 322)
$txtInstructions.Size = New-Object System.Drawing.Size(850, 128)
$txtInstructions.Font = New-Object System.Drawing.Font("Consolas", 9.0)
$panelWebOptions.Controls.Add($txtInstructions)

$refreshWebProfilesGrid = {
    $webGrid.Rows.Clear()
    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.Profiles) { return }

    foreach ($p in $liveCfg.Profiles) {
        if ($p.Separator) { continue }
        $rowIdx = $webGrid.Rows.Add()
        $row = $webGrid.Rows[$rowIdx]
        $row.Tag = $p.Name

        $isVisible = $true
        if ($null -ne $p.WebVisible) {
            $isVisible = [bool]$p.WebVisible
        } elseif ([bool]$p.Hidden) {
            $isVisible = $false
        }
        $row.Cells["WebVisible"].Value = $isVisible

        $title = if ($p.Label) { $p.Label } else { $p.Name }
        $row.Cells["ProfileTitle"].Value = $title

        $defaultIcon = "🖥️"
        $defaultColor = "#3b82f6"
        $lowName = ($p.Name + " " + $p.Label).ToLower()
        if ($lowName -match "tv") { $defaultIcon = "📺"; $defaultColor = "#f59e0b" }
        elseif ($lowName -match "race|rig") { $defaultIcon = "🏎️"; $defaultColor = "#ef4444" }
        elseif ($lowName -match "vr") { $defaultIcon = "🥽"; $defaultColor = "#ec4899" }
        elseif ($p.IsToggle -or $lowName -match "toggle|single") { $defaultIcon = "🔄"; $defaultColor = "#8b5cf6" }

        $row.Cells["WebIcon"].Value = if ($p.WebIcon) { $p.WebIcon } else { $defaultIcon }
        $row.Cells["WebColor"].Value = if ($p.WebColor) { $p.WebColor } else { $defaultColor }
    }
}

$updateWebTabDisplay = {
    $dom = $txtWebDomain.Text.Trim()
    if (-not $dom) { $dom = "localhost" }
    $port = [int]$numWebPort.Value
    $lnkDomain.Text = "https://$dom"

    $liveCfg = Get-LiveConfig
    $urlList = @()
    if ($liveCfg.Profiles) {
        foreach ($p in $liveCfg.Profiles) {
            if ($p.Separator -or [bool]$p.Hidden) { continue }
            $cleanSlug = ($p.Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
            $urlList += "  POST https://$dom/api/profile/$cleanSlug  # ($($p.Name))"
        }
    }
    $urlBlock = ($urlList -join "`r`n")

    $txtInstructions.Text = @"
IPHONE & SIRI SHORTCUTS QUICK SETUP:
1. Open Safari on your phone -> Go to: https://$dom (or http://192.168.1.200:$port)
2. Tap the Safari Share icon -> Tap 'Add to Home Screen' for the 1-touch dashboard.
3. Siri Shortcuts URL endpoints (Clean, no spaces or special characters!):
$urlBlock

How to use in iOS Shortcuts app:
- Add action: 'Get Contents of URL'
- Set Method to: POST
- Paste any of the URLs above!
"@
}

$txtWebDomain.add_TextChanged({ & $updateWebTabDisplay })
$numWebPort.add_ValueChanged({ & $updateWebTabDisplay })
& $updateWebTabDisplay

$tabWeb.Controls.Add($webBox)
$tabs.TabPages.Add($tabWeb)

# ==============================================================================
# TAB 5: Advanced Hardware & Safety Settings (Protected / Greyed Out)
# ==============================================================================
$tabAdv = New-Object System.Windows.Forms.TabPage("Advanced Hardware")
$tabAdv.BackColor = [System.Drawing.Color]::White

$advBox = New-Object System.Windows.Forms.GroupBox
$advBox.Text = "Hardware Timing, PnP Sequencing & Driver Safety (Configurable)"
$advBox.Location = New-Object System.Drawing.Point(15, 15)
$advBox.Size = New-Object System.Drawing.Size(950, 500)

$chkUnlockAdv = New-Object System.Windows.Forms.CheckBox
$chkUnlockAdv.Text = "Allow editing Advanced Hardware Parameters (Timing, Delays & Guard Timeouts)"
$chkUnlockAdv.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$chkUnlockAdv.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$chkUnlockAdv.Location = New-Object System.Drawing.Point(20, 25)
$chkUnlockAdv.Size = New-Object System.Drawing.Size(780, 25)
$advBox.Controls.Add($chkUnlockAdv)

$panelAdvFields = New-Object System.Windows.Forms.Panel
$panelAdvFields.Location = New-Object System.Drawing.Point(20, 60)
$panelAdvFields.Size = New-Object System.Drawing.Size(910, 420)
$panelAdvFields.Enabled = $false
$advBox.Controls.Add($panelAdvFields)

# Field 1: UsbToggleDelayMs
$lblUsbDelay = New-Object System.Windows.Forms.Label
$lblUsbDelay.Text = "USB PnP Device Transition Delay (ms):"
$lblUsbDelay.Location = New-Object System.Drawing.Point(0, 15)
$lblUsbDelay.AutoSize = $true
$panelAdvFields.Controls.Add($lblUsbDelay)

$numUsbDelay = New-Object System.Windows.Forms.NumericUpDown
$numUsbDelay.Minimum = 0
$numUsbDelay.Maximum = 2000
$numUsbDelay.Value = 250
$numUsbDelay.Location = New-Object System.Drawing.Point(380, 12)
$numUsbDelay.Size = New-Object System.Drawing.Size(100, 26)
$panelAdvFields.Controls.Add($numUsbDelay)

$lblUsbDelayHelp = New-Object System.Windows.Forms.Label
$lblUsbDelayHelp.Text = "Pause between individual device enable/disable calls to prevent kernel driver collisions."
$lblUsbDelayHelp.ForeColor = [System.Drawing.Color]::Gray
$lblUsbDelayHelp.Location = New-Object System.Drawing.Point(0, 38)
$lblUsbDelayHelp.AutoSize = $true
$panelAdvFields.Controls.Add($lblUsbDelayHelp)

# Field 2: PreSwitchPlugDelayMs
$lblPlugDelay = New-Object System.Windows.Forms.Label
$lblPlugDelay.Text = "Smart Plug Pre-Switch Settle Delay (ms):"
$lblPlugDelay.Location = New-Object System.Drawing.Point(0, 75)
$lblPlugDelay.AutoSize = $true
$panelAdvFields.Controls.Add($lblPlugDelay)

$numPlugDelay = New-Object System.Windows.Forms.NumericUpDown
$numPlugDelay.Minimum = 0
$numPlugDelay.Maximum = 5000
$numPlugDelay.Value = 1200
$numPlugDelay.Location = New-Object System.Drawing.Point(380, 72)
$numPlugDelay.Size = New-Object System.Drawing.Size(100, 26)
$panelAdvFields.Controls.Add($numPlugDelay)

$lblPlugDelayHelp = New-Object System.Windows.Forms.Label
$lblPlugDelayHelp.Text = "Delay after turning on display smart plugs so the GPU finishes HDMI/DP handshakes before topology applies."
$lblPlugDelayHelp.ForeColor = [System.Drawing.Color]::Gray
$lblPlugDelayHelp.Location = New-Object System.Drawing.Point(0, 98)
$lblPlugDelayHelp.AutoSize = $true
$panelAdvFields.Controls.Add($lblPlugDelayHelp)

# Field 3: DisplaySwitchTimeoutSeconds
$lblTimeout = New-Object System.Windows.Forms.Label
$lblTimeout.Text = "Display Topology Switch Timeout Guard (seconds):"
$lblTimeout.Location = New-Object System.Drawing.Point(0, 135)
$lblTimeout.AutoSize = $true
$panelAdvFields.Controls.Add($lblTimeout)

$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Minimum = 1
$numTimeout.Maximum = 30
$numTimeout.Value = 7
$numTimeout.Location = New-Object System.Drawing.Point(380, 132)
$numTimeout.Size = New-Object System.Drawing.Size(100, 26)
$panelAdvFields.Controls.Add($numTimeout)

$lblTimeoutHelp = New-Object System.Windows.Forms.Label
$lblTimeoutHelp.Text = "Hard timeout to force-terminate hanging display switch calls and prevent locking up the Windows session."
$lblTimeoutHelp.ForeColor = [System.Drawing.Color]::Gray
$lblTimeoutHelp.Location = New-Object System.Drawing.Point(0, 158)
$lblTimeoutHelp.AutoSize = $true
$panelAdvFields.Controls.Add($lblTimeoutHelp)

# Field 4: PurgePhantomUsbDevices
$chkPurgePhantom = New-Object System.Windows.Forms.CheckBox
$chkPurgePhantom.Text = "Automatically purge crashed/phantom 'Unknown USB Device' descriptor nodes (VID_0000)"
$chkPurgePhantom.Checked = $true
$chkPurgePhantom.Location = New-Object System.Drawing.Point(0, 200)
$chkPurgePhantom.Size = New-Object System.Drawing.Size(700, 25)
$panelAdvFields.Controls.Add($chkPurgePhantom)

# Field 5: PrioritizeHubOrder
$chkPrioritizeHub = New-Object System.Windows.Forms.CheckBox
$chkPrioritizeHub.Text = "Strict Hierarchy: Enable root USB hubs before devices, and disable downstream devices before hubs"
$chkPrioritizeHub.Checked = $true
$chkPrioritizeHub.Location = New-Object System.Drawing.Point(0, 235)
$chkPrioritizeHub.Size = New-Object System.Drawing.Size(700, 25)
$panelAdvFields.Controls.Add($chkPrioritizeHub)

# Field 6: Start with Windows
$chkStartOnBoot = New-Object System.Windows.Forms.CheckBox
$chkStartOnBoot.Text = "Start DeskShift automatically with Windows (User Login)"
$chkStartOnBoot.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$chkStartOnBoot.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$chkStartOnBoot.Location = New-Object System.Drawing.Point(0, 275)
$chkStartOnBoot.Size = New-Object System.Drawing.Size(700, 25)
$regRunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$regRunName = "DeskShift"
$chkStartOnBoot.Checked = ($null -ne (Get-ItemProperty -Path $regRunPath -Name $regRunName -ErrorAction SilentlyContinue))
$panelAdvFields.Controls.Add($chkStartOnBoot)

$chkUnlockAdv.add_CheckedChanged({
    $panelAdvFields.Enabled = $chkUnlockAdv.Checked
})

$advBox.Controls.Add($panelAdvFields)
$tabAdv.Controls.Add($advBox)
$tabs.TabPages.Add($tabAdv)

$form.Controls.Add($tabs)

# ==============================================================================
# BOTTOM ACTION BUTTONS
# ==============================================================================
$chkStartOnBootMain = New-Object System.Windows.Forms.CheckBox
$chkStartOnBootMain.Text = "Start DeskShift with Windows"
$chkStartOnBootMain.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$chkStartOnBootMain.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$chkStartOnBootMain.Location = New-Object System.Drawing.Point(20, 658)
$chkStartOnBootMain.Size = New-Object System.Drawing.Size(260, 28)
$regRunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$regRunName = "DeskShift"
$chkStartOnBootMain.Checked = ($null -ne (Get-ItemProperty -Path $regRunPath -Name $regRunName -ErrorAction SilentlyContinue))
$form.Controls.Add($chkStartOnBootMain)

$saveBtn = New-Object System.Windows.Forms.Button
$saveBtn.Text = "Save All Settings & Sync"
$saveBtn.Location = New-Object System.Drawing.Point(680, 655)
$saveBtn.Size = New-Object System.Drawing.Size(200, 34)
$saveBtn.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$saveBtn.ForeColor = [System.Drawing.Color]::White
$saveBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$saveBtn.FlatStyle = "Flat"
$saveBtn.FlatAppearance.BorderSize = 0

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = "Close"
$closeBtn.Location = New-Object System.Drawing.Point(890, 655)
$closeBtn.Size = New-Object System.Drawing.Size(110, 34)
$closeBtn.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$closeBtn.FlatStyle = "Flat"
$closeBtn.FlatAppearance.BorderSize = 0

$form.Controls.Add($saveBtn)
$form.Controls.Add($closeBtn)

# Helper function to get device live status string
function Get-DeviceLiveStatus ($instanceId) {
    $pnp = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
    if (-not $pnp -or -not $pnp.Present) { return "Disconnected" }
    if ($pnp.Status -eq "OK") { return "ON (Active)" }
    return "OFF (Disabled)"
}

# Function to populate Device List immediately with cached config and live status
$refreshDeviceList = {
    $deviceListView.Items.Clear()
    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.DeviceDefinitions) { return }

    # Query all present PnP devices in one bulk call (~600ms)
    $pnpMap = @{}
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $pnpMap[$_.InstanceId] = $_.Status }

    foreach ($prop in $liveCfg.DeviceDefinitions.PSObject.Properties) {
        $dev = $prop.Value
        $id = $dev.InstanceId
        $status = if ($pnpMap.ContainsKey($id)) {
            if ($pnpMap[$id] -eq "OK") { "ON (Active)" } else { "OFF (Disabled)" }
        } else {
            "Disconnected"
        }

        $item = New-Object System.Windows.Forms.ListViewItem($dev.Name)
        $item.SubItems.Add($prop.Name) | Out-Null
        $item.SubItems.Add($status) | Out-Null
        $item.SubItems.Add($id) | Out-Null
        $item.Tag = [PSCustomObject]@{ Key = $prop.Name; InstanceId = $id; Name = $dev.Name; Status = $status }
        $deviceListView.Items.Add($item) | Out-Null
    }
}

# Function to populate Smart Plugs ListView & Credentials
$refreshPlugsInputs = {
    $plugListView.Items.Clear()
    $liveCfg = Get-LiveConfig

    if ($liveCfg.SmartPlugs) {
        foreach ($pProp in $liveCfg.SmartPlugs.PSObject.Properties) {
            $pk = $pProp.Name
            $p = $pProp.Value
            $pType = if ($p.Type) { $p.Type } else { "Tapo" }
            $authReq = if ($pType -match "Kasa") { "None (Port 9999)" }
                       elseif ($pType -match "Tapo") { "Local KLAP" }
                       elseif ($pType -match "HomeAssistant|Hass") { "Bearer Token" }
                       elseif ($pType -match "Webhook|HTTP") { "HTTP REST" }
                       else { "CLI Exec" }

            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $item.SubItems.Add($pk) | Out-Null
            $item.SubItems.Add($pType) | Out-Null
            $item.SubItems.Add($p.Ip) | Out-Null
            $item.SubItems.Add($authReq) | Out-Null
            $item.Tag = [PSCustomObject]@{ Key = $pk; Name = $p.Name; Type = $pType; Ip = $p.Ip; OffAction = $(if ($p.OffCommand) { $p.OffCommand } elseif ($p.OffUrl) { $p.OffUrl } else { "" }) }
            $plugListView.Items.Add($item) | Out-Null
        }
    }

    if ($liveCfg.TapoCredentials) {
        $txtEmail.Text = $liveCfg.TapoCredentials.Email
        $txtPass.Text = $liveCfg.TapoCredentials.Password
    }
}

# Populate Add/Edit boxes when clicking a plug
$plugListView.add_SelectedIndexChanged({
    if ($plugListView.SelectedItems.Count -gt 0) {
        $sel = $plugListView.SelectedItems[0].Tag
        $txtPlugKey.Text = $sel.Key
        $txtPlugName.Text = $sel.Name
        $txtPlugIp.Text = $sel.Ip
        $txtPlugOff.Text = if ($sel.OffAction) { $sel.OffAction } else { "" }
        if ($sel.Type -match "Kasa") { $cmbPlugType.SelectedIndex = 0 }
        elseif ($sel.Type -match "Tapo") { $cmbPlugType.SelectedIndex = 1 }
        elseif ($sel.Type -match "HomeAssistant|Hass") { $cmbPlugType.SelectedIndex = 2 }
        elseif ($sel.Type -match "Webhook|HTTP") { $cmbPlugType.SelectedIndex = 3 }
        else { $cmbPlugType.SelectedIndex = 4 }
    }
})

# Save / Add Plug Button Click
$btnSavePlug.add_Click({
    $key = $txtPlugKey.Text.Trim()
    $name = $txtPlugName.Text.Trim()
    $ip = $txtPlugIp.Text.Trim()
    $offAction = $txtPlugOff.Text.Trim()
    $typeMap = @("Kasa", "Tapo", "HomeAssistant", "Webhook", "Custom")
    $type = if ($cmbPlugType.SelectedIndex -ge 0 -and $cmbPlugType.SelectedIndex -lt $typeMap.Count) { $typeMap[$cmbPlugType.SelectedIndex] } else { "Tapo" }

    if (-not $key -or -not $name -or -not $ip) {
        [System.Windows.Forms.MessageBox]::Show("Please provide Plug Key, Name, and Target Address/Command.", "Missing Field", "OK", "Warning")
        return
    }

    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.SmartPlugs) {
        $liveCfg | Add-Member -MemberType NoteProperty -Name "SmartPlugs" -Value (New-Object PSObject)
    }

    if ($liveCfg.SmartPlugs.PSObject.Properties[$key]) {
        $liveCfg.SmartPlugs.$key.Name = $name
        $liveCfg.SmartPlugs.$key.Type = $type
        $liveCfg.SmartPlugs.$key.Ip = $ip
        if ($type -eq "Webhook") {
            if ($offAction) { $liveCfg.SmartPlugs.$key | Add-Member -MemberType NoteProperty -Name "OffUrl" -Value $offAction -Force }
        } elseif ($type -eq "Custom") {
            if ($offAction) { $liveCfg.SmartPlugs.$key | Add-Member -MemberType NoteProperty -Name "OffCommand" -Value $offAction -Force }
        }
    } else {
        $newPlug = [PSCustomObject]@{
            Name = $name
            Type = $type
            Ip = $ip
        }
        if ($type -eq "Webhook" -and $offAction) {
            $newPlug | Add-Member -MemberType NoteProperty -Name "OffUrl" -Value $offAction
        } elseif ($type -eq "Custom" -and $offAction) {
            $newPlug | Add-Member -MemberType NoteProperty -Name "OffCommand" -Value $offAction
        }
        $liveCfg.SmartPlugs | Add-Member -MemberType NoteProperty -Name $key -Value $newPlug
    }

    Save-LiveConfig -cfg $liveCfg
    & $refreshPlugsInputs
    & $refreshMatrixGrid
    [System.Windows.Forms.MessageBox]::Show("Smart plug '$name' saved successfully!", "Saved", "OK", "Information")
})

# Delete Plug Button Click
$btnDeletePlug.add_Click({
    if ($plugListView.SelectedItems.Count -eq 0) { return }
    $selKey = $plugListView.SelectedItems[0].Tag.Key
    
    $confirm = [System.Windows.Forms.MessageBox]::Show("Delete smart plug '$selKey'?", "Confirm Delete", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        $liveCfg = Get-LiveConfig
        if ($liveCfg.SmartPlugs -and $liveCfg.SmartPlugs.PSObject.Properties[$selKey]) {
            $liveCfg.SmartPlugs.PSObject.Properties.Remove($selKey)
            
            # Also clean up references in profiles
            foreach ($prof in $liveCfg.Profiles) {
                if ($prof.Plugs -and $prof.Plugs.PSObject.Properties[$selKey]) {
                    $prof.Plugs.PSObject.Properties.Remove($selKey)
                }
            }

            Save-LiveConfig -cfg $liveCfg
            & $refreshPlugsInputs
            & $refreshMatrixGrid
        }
    }
})

# ==============================================================================
# TRANSPOSED MATRIX GRID: Devices/Plugs as Rows, Profiles as Columns
# ==============================================================================
$refreshMatrixGrid = {
    $matrixGrid.Columns.Clear()
    $matrixGrid.Rows.Clear()
    $liveCfg = Get-LiveConfig

    # First Column: Device / Plug Name
    $devCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $devCol.HeaderText = "Hardware / Power Device"
    $devCol.Name = "DeviceName"
    $devCol.ReadOnly = $true
    $devCol.Frozen = $true
    $matrixGrid.Columns.Add($devCol) | Out-Null

    # Filter active display profiles to become the Columns
    $validProfiles = @()
    foreach ($prof in $liveCfg.Profiles) {
        if ($prof.Separator -or $prof.Hidden) { continue }
        $validProfiles += $prof

        $colName = "PROF_" + $prof.Name
        $pCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
        $pCol.HeaderText = if ($prof.Label) { $prof.Label } else { $prof.Name }
        $pCol.Name = $colName
        $matrixGrid.Columns.Add($pCol) | Out-Null
    }

    # 1. Add Rows for Smart Plugs (at top)
    if ($liveCfg.SmartPlugs) {
        foreach ($pProp in $liveCfg.SmartPlugs.PSObject.Properties) {
            $pk = $pProp.Name
            $p = $pProp.Value
            $rowIdx = $matrixGrid.Rows.Add()
            $row = $matrixGrid.Rows[$rowIdx]
            $row.Cells["DeviceName"].Value = "[PLUG] " + $p.Name
            $row.Tag = [PSCustomObject]@{ Category = "PLUG"; Key = $pk }

            # Populate checkbox state for each profile column
            foreach ($prof in $validProfiles) {
                $colName = "PROF_" + $prof.Name
                $isEnabled = $false
                if ($prof.Plugs -and $prof.Plugs.PSObject.Properties[$pk]) {
                    $isEnabled = [bool]$prof.Plugs.$pk
                }
                $row.Cells[$colName].Value = $isEnabled
            }
        }
    }

    # 2. Add Rows for Managed USB Devices
    if ($liveCfg.DeviceDefinitions) {
        foreach ($dProp in $liveCfg.DeviceDefinitions.PSObject.Properties) {
            $dk = $dProp.Name
            $d = $dProp.Value
            $rowIdx = $matrixGrid.Rows.Add()
            $row = $matrixGrid.Rows[$rowIdx]
            $row.Cells["DeviceName"].Value = "[USB] " + $d.Name
            $row.Tag = [PSCustomObject]@{ Category = "USB"; Key = $dk }

            # Populate checkbox state for each profile column
            foreach ($prof in $validProfiles) {
                $colName = "PROF_" + $prof.Name
                $isEnabled = $false
                if ($prof.Devices -and $prof.Devices.PSObject.Properties[$dk]) {
                    $isEnabled = [bool]$prof.Devices.$dk
                }
                $row.Cells[$colName].Value = $isEnabled
            }
        }
    }

    # Populate Target Profile Dropdown on Toolbar with consistent profile objects
    $cmbProfiles.Items.Clear()
    $cmbProfiles.DisplayMember = "Display"
    $cmbProfiles.ValueMember = "Name"
    foreach ($prof in $validProfiles) {
        $displayTitle = if ($prof.Label) { $prof.Label } else { $prof.Name }
        $itemObj = [PSCustomObject]@{
            Display = $displayTitle
            Name    = $prof.Name
            Profile = $prof
        }
        $cmbProfiles.Items.Add($itemObj) | Out-Null
    }
    if ($cmbProfiles.Items.Count -gt 0 -and $cmbProfiles.SelectedIndex -lt 0) {
        $cmbProfiles.SelectedIndex = 0
    }
}

# Capture Live Displays to Selected Profile Button Handler
$btnCaptureLayout.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a target profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $targetProfName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1

    $engineExe = Join-Path $scriptDir "bin\NativeEngine.exe"

    if (-not (Test-Path -LiteralPath $engineExe)) {
        [System.Windows.Forms.MessageBox]::Show("NativeEngine.exe not found in bin\.", "Error", "OK", "Error")
        return
    }

    # If user selected a toggle profile, ask which stage in the toggle cycle to snapshot
    $targetFile = "$targetProfName.native.json"
    if ($profObj -and $profObj.IsToggle) {
        $cycleList = if ($profObj.ToggleCycle -and $profObj.ToggleCycle.Count -gt 0) {
            @($profObj.ToggleCycle)
        } else {
            @("Desk (Single Right)", "Desk (Single Left)")
        }

        # Prompt user to choose which toggle stage they want to capture
        $cyclePrompt = New-Object System.Windows.Forms.Form
        $cyclePrompt.Text = "Select Toggle Stage to Capture"
        $cyclePrompt.Size = New-Object System.Drawing.Size(380, 200)
        $cyclePrompt.StartPosition = "CenterParent"
        $cyclePrompt.FormBorderStyle = "FixedDialog"
        $cyclePrompt.MaximizeBox = $false
        $cyclePrompt.MinimizeBox = $false

        $cLabel = New-Object System.Windows.Forms.Label
        $cLabel.Text = "Select which toggle step you are capturing right now:"
        $cLabel.Location = New-Object System.Drawing.Point(20, 15)
        $cLabel.Size = New-Object System.Drawing.Size(340, 25)
        $cyclePrompt.Controls.Add($cLabel)

        $cmbCycle = New-Object System.Windows.Forms.ComboBox
        $cmbCycle.DropDownStyle = "DropDownList"
        $cmbCycle.Location = New-Object System.Drawing.Point(20, 45)
        $cmbCycle.Size = New-Object System.Drawing.Size(320, 25)
        foreach ($cItem in $cycleList) {
            $cmbCycle.Items.Add($cItem) | Out-Null
        }
        if ($cmbCycle.Items.Count -gt 0) { $cmbCycle.SelectedIndex = 0 }
        $cyclePrompt.Controls.Add($cmbCycle)

        $btnCOk = New-Object System.Windows.Forms.Button
        $btnCOk.Text = "Capture This Step"
        $btnCOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnCOk.Location = New-Object System.Drawing.Point(130, 95)
        $btnCOk.Size = New-Object System.Drawing.Size(120, 30)
        $btnCOk.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
        $btnCOk.ForeColor = [System.Drawing.Color]::White
        $btnCOk.FlatStyle = "Flat"
        $cyclePrompt.Controls.Add($btnCOk)

        $btnCCancel = New-Object System.Windows.Forms.Button
        $btnCCancel.Text = "Cancel"
        $btnCCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $btnCCancel.Location = New-Object System.Drawing.Point(260, 95)
        $btnCCancel.Size = New-Object System.Drawing.Size(80, 30)
        $cyclePrompt.Controls.Add($btnCCancel)
        $cyclePrompt.AcceptButton = $btnCOk
        $cyclePrompt.CancelButton = $btnCCancel

        if ($cyclePrompt.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or -not $cmbCycle.SelectedItem) {
            return
        }
        $subTargetName = $cmbCycle.SelectedItem.ToString()
        $targetFile = "$subTargetName.native.json"
        $targetProfName = $subTargetName
    }

    $outJsonPath = Join-Path $configDir $targetFile
    $proc = Start-Process -FilePath $engineExe -ArgumentList @("display", "capture", "`"$targetProfName`"", "`"$outJsonPath`"") -WorkingDirectory $scriptDir -WindowStyle Hidden -Wait -PassThru

    if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $outJsonPath)) {
        # Automatically snapshot live Windows DPI scaling percentages into profile
        $capturedScales = Get-CurrentDisplayScales -AppRoot $scriptDir
        $scaleSummaryList = @()
        if ($capturedScales.Count -gt 0) {
            $targetProf = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1
            if ($targetProf) {
                if ($targetProf.PSObject.Properties["DisplayScales"]) {
                    $targetProf.DisplayScales = [PSCustomObject]$capturedScales
                } else {
                    $targetProf | Add-Member -MemberType NoteProperty -Name "DisplayScales" -Value ([PSCustomObject]$capturedScales)
                }
                Save-LiveConfig -cfg $liveCfg
                foreach ($k in $capturedScales.Keys) {
                    $scaleSummaryList += "Display ${k}: $($capturedScales[$k])%"
                }
            }
        }

        $scaleMsg = if ($scaleSummaryList.Count -gt 0) {
            "`n`nWindows DPI Scaling Saved:`n" + ($scaleSummaryList -join ", ")
        } else { "" }

        [System.Windows.Forms.MessageBox]::Show("Current display layout & Windows scaling successfully captured to '$targetFile'!$scaleMsg`n`nMonitors, resolutions, coordinates, refresh rates, and DPI scaling are locked in.", "Capture Succeeded", "OK", "Information")
    } else {
        [System.Windows.Forms.MessageBox]::Show("Failed to capture display layout (Exit code: $($proc.ExitCode)).", "Capture Failed", "OK", "Error")
    }
})

# Create New Profile Button Handler
$btnNewProfile.add_Click({
    $prompt = New-Object System.Windows.Forms.Form
    $prompt.Text = "Create New Display Profile"
    $prompt.Size = New-Object System.Drawing.Size(420, 260)
    $prompt.StartPosition = "CenterParent"
    $prompt.FormBorderStyle = "FixedDialog"
    $prompt.MaximizeBox = $false
    $prompt.MinimizeBox = $false

    $pLabel = New-Object System.Windows.Forms.Label
    $pLabel.Text = "Profile Name (e.g. 'Sim Rig 1440p', 'Office Focus'):"
    $pLabel.Location = New-Object System.Drawing.Point(20, 15)
    $pLabel.AutoSize = $true
    $prompt.Controls.Add($pLabel)

    $pBox = New-Object System.Windows.Forms.TextBox
    $pBox.Location = New-Object System.Drawing.Point(20, 38)
    $pBox.Size = New-Object System.Drawing.Size(360, 25)
    $prompt.Controls.Add($pBox)

    $pLabel2 = New-Object System.Windows.Forms.Label
    $pLabel2.Text = "Display Label (short name for tray menu):"
    $pLabel2.Location = New-Object System.Drawing.Point(20, 75)
    $pLabel2.AutoSize = $true
    $prompt.Controls.Add($pLabel2)

    $pBox2 = New-Object System.Windows.Forms.TextBox
    $pBox2.Location = New-Object System.Drawing.Point(20, 98)
    $pBox2.Size = New-Object System.Drawing.Size(360, 25)
    $prompt.Controls.Add($pBox2)

    $liveDefaultAudio = Get-LiveDefaultAudioName
    $lblAudioDesc = if ($liveDefaultAudio) { "Live Active: $liveDefaultAudio" } else { "No active endpoint detected" }

    $pLabel3 = New-Object System.Windows.Forms.Label
    $pLabel3.Text = "Default Audio Output Device (optional):"
    $pLabel3.Location = New-Object System.Drawing.Point(20, 135)
    $pLabel3.AutoSize = $true
    $prompt.Controls.Add($pLabel3)

    $cmbAudioNew = New-Object System.Windows.Forms.ComboBox
    $cmbAudioNew.DropDownStyle = "DropDownList"
    $cmbAudioNew.Location = New-Object System.Drawing.Point(20, 158)
    $cmbAudioNew.Size = New-Object System.Drawing.Size(360, 25)
    $cmbAudioNew.Items.Add("[No Audio Change - Keep Current]") | Out-Null
    $audioEndpoints = Get-ActiveAudioEndpoints
    $selectedAudioIdx = 0
    for ($a = 0; $a -lt $audioEndpoints.Count; $a++) {
        $ep = $audioEndpoints[$a]
        $cmbAudioNew.Items.Add($ep.Display) | Out-Null
        if ($liveDefaultAudio -and $ep.Display -eq $liveDefaultAudio) {
            $selectedAudioIdx = $a + 1
        }
    }
    $cmbAudioNew.SelectedIndex = $selectedAudioIdx
    $prompt.Controls.Add($cmbAudioNew)

    $chkCaptureNow = New-Object System.Windows.Forms.CheckBox
    $chkCaptureNow.Text = "Snapshot current monitor layout to this profile immediately"
    $chkCaptureNow.Checked = $true
    $chkCaptureNow.Location = New-Object System.Drawing.Point(20, 195)
    $chkCaptureNow.AutoSize = $true
    $prompt.Controls.Add($chkCaptureNow)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Create Profile"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = New-Object System.Drawing.Point(180, 230)
    $btnOk.Size = New-Object System.Drawing.Size(100, 30)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = "Flat"
    $prompt.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(290, 230)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $prompt.Controls.Add($btnCancel)
    $prompt.AcceptButton = $btnOk
    $prompt.CancelButton = $btnCancel

    $prompt.Size = New-Object System.Drawing.Size(420, 315)

    if ($prompt.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pName = $pBox.Text.Trim()
        $pLbl = $pBox2.Text.Trim()
        if (-not $pLbl) { $pLbl = $pName }

        if (-not $pName) {
            [System.Windows.Forms.MessageBox]::Show("Profile name cannot be empty.", "Error", "OK", "Warning")
            return
        }

        $liveCfg = Get-LiveConfig
        if ($liveCfg.Profiles | Where-Object { $_.Name -eq $pName }) {
            [System.Windows.Forms.MessageBox]::Show("A profile with that name already exists.", "Duplicate", "OK", "Warning")
            return
        }

        # Create new profile object
        $chosenAudio = ""
        if ($cmbAudioNew.SelectedIndex -gt 0) {
            $chosenAudio = $cmbAudioNew.SelectedItem.ToString()
        }

        $newProf = [PSCustomObject]@{
            Name          = $pName
            Label         = $pLbl
            AudioDevice   = $chosenAudio
            LaunchApp     = ""
            LaunchAppArgs = ""
            Devices       = (New-Object PSObject)
            Plugs         = (New-Object PSObject)
        }
        $liveCfg.Profiles += $newProf
        Save-LiveConfig -cfg $liveCfg

        # Optional immediate capture
        if ($chkCaptureNow.Checked) {
            $engineExe = Join-Path $scriptDir "bin\NativeEngine.exe"
            $outJsonPath = Join-Path $configDir "$pName.native.json"
            Start-Process -FilePath $engineExe -ArgumentList @("display", "capture", "`"$pName`"", "`"$outJsonPath`"") -WorkingDirectory $scriptDir -WindowStyle Hidden -Wait | Out-Null

            $capturedScales = Get-CurrentDisplayScales -AppRoot $scriptDir
            if ($capturedScales.Count -gt 0) {
                $newProf | Add-Member -MemberType NoteProperty -Name "DisplayScales" -Value ([PSCustomObject]$capturedScales) -Force
                Save-LiveConfig -cfg $liveCfg
            }
        }

        & $refreshMatrixGrid
        if ($refreshWebProfilesGrid) { & $refreshWebProfilesGrid }
        if ($updateWebTabDisplay) { & $updateWebTabDisplay }
        # Select newly created profile in dropdown
        for ($i = 0; $i -lt $cmbProfiles.Items.Count; $i++) {
            if ($cmbProfiles.Items[$i].Name -eq $pName) {
                $cmbProfiles.SelectedIndex = $i
                break
            }
        }
        [System.Windows.Forms.MessageBox]::Show("Profile '$pName' created successfully!", "Created", "OK", "Information")
    }
})

# Configure Toggle Cycle Button Handler
$btnConfigToggle.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a target profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $targetProfName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1

    if (-not $profObj) { return }

    $dlgToggle = New-Object System.Windows.Forms.Form
    $dlgToggle.Text = "Configure Toggle Cycle - $targetProfName"
    $dlgToggle.Size = New-Object System.Drawing.Size(520, 480)
    $dlgToggle.StartPosition = "CenterParent"
    $dlgToggle.FormBorderStyle = "FixedDialog"
    $dlgToggle.MaximizeBox = $false
    $dlgToggle.MinimizeBox = $false

    $chkIsToggle = New-Object System.Windows.Forms.CheckBox
    $chkIsToggle.Text = "Enable Toggle Mode for this profile (cycles through sub-profiles on each click)"
    $chkIsToggle.Checked = [bool]$profObj.IsToggle
    $chkIsToggle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
    $chkIsToggle.Location = New-Object System.Drawing.Point(20, 15)
    $chkIsToggle.AutoSize = $true
    $dlgToggle.Controls.Add($chkIsToggle)

    $lblSteps = New-Object System.Windows.Forms.Label
    $lblSteps.Text = "Toggle Cycle Sequence (1st click -> 2nd click -> 3rd click...):"
    $lblSteps.Location = New-Object System.Drawing.Point(20, 50)
    $lblSteps.AutoSize = $true
    $dlgToggle.Controls.Add($lblSteps)

    # CheckedListBox showing current toggle sequence
    $lstSequence = New-Object System.Windows.Forms.ListBox
    $lstSequence.Location = New-Object System.Drawing.Point(20, 75)
    $lstSequence.Size = New-Object System.Drawing.Size(350, 180)
    $dlgToggle.Controls.Add($lstSequence)

    # Populate existing cycle sequence
    $currentCycle = if ($profObj.ToggleCycle) { @($profObj.ToggleCycle) } else { @("Desk (Single Right)", "Desk (Single Left)") }
    foreach ($cItem in $currentCycle) {
        $lstSequence.Items.Add($cItem) | Out-Null
    }

    # Up, Down, Remove buttons for order
    $btnMoveUp = New-Object System.Windows.Forms.Button
    $btnMoveUp.Text = "Move Up"
    $btnMoveUp.Location = New-Object System.Drawing.Point(380, 75)
    $btnMoveUp.Size = New-Object System.Drawing.Size(100, 28)
    $dlgToggle.Controls.Add($btnMoveUp)

    $btnMoveDown = New-Object System.Windows.Forms.Button
    $btnMoveDown.Text = "Move Down"
    $btnMoveDown.Location = New-Object System.Drawing.Point(380, 110)
    $btnMoveDown.Size = New-Object System.Drawing.Size(100, 28)
    $dlgToggle.Controls.Add($btnMoveDown)

    $btnRemoveStep = New-Object System.Windows.Forms.Button
    $btnRemoveStep.Text = "Remove"
    $btnRemoveStep.Location = New-Object System.Drawing.Point(380, 145)
    $btnRemoveStep.Size = New-Object System.Drawing.Size(100, 28)
    $dlgToggle.Controls.Add($btnRemoveStep)

    $btnMoveUp.add_Click({
        $idx = $lstSequence.SelectedIndex
        if ($idx -gt 0) {
            $item = $lstSequence.Items[$idx]
            $lstSequence.Items.RemoveAt($idx)
            $lstSequence.Items.Insert($idx - 1, $item)
            $lstSequence.SelectedIndex = $idx - 1
        }
    })

    $btnMoveDown.add_Click({
        $idx = $lstSequence.SelectedIndex
        if ($idx -ge 0 -and $idx -lt ($lstSequence.Items.Count - 1)) {
            $item = $lstSequence.Items[$idx]
            $lstSequence.Items.RemoveAt($idx)
            $lstSequence.Items.Insert($idx + 1, $item)
            $lstSequence.SelectedIndex = $idx + 1
        }
    })

    $btnRemoveStep.add_Click({
        $idx = $lstSequence.SelectedIndex
        if ($idx -ge 0) {
            $lstSequence.Items.RemoveAt($idx)
        }
    })

    # Add Step Section
    $lblAdd = New-Object System.Windows.Forms.Label
    $lblAdd.Text = "Add display profile or snapshot to cycle:"
    $lblAdd.Location = New-Object System.Drawing.Point(20, 270)
    $lblAdd.AutoSize = $true
    $dlgToggle.Controls.Add($lblAdd)

    $cmbAvailableProfs = New-Object System.Windows.Forms.ComboBox
    $cmbAvailableProfs.DropDownStyle = "DropDownList"
    $cmbAvailableProfs.Location = New-Object System.Drawing.Point(20, 295)
    $cmbAvailableProfs.Size = New-Object System.Drawing.Size(260, 25)
    foreach ($p in $liveCfg.Profiles) {
        if ($p.Name -and $p.Name -ne $targetProfName) {
            $cmbAvailableProfs.Items.Add($p.Name) | Out-Null
        }
    }
    if ($cmbAvailableProfs.Items.Count -gt 0) { $cmbAvailableProfs.SelectedIndex = 0 }
    $dlgToggle.Controls.Add($cmbAvailableProfs)

    $btnAddProfile = New-Object System.Windows.Forms.Button
    $btnAddProfile.Text = "+ Add Existing"
    $btnAddProfile.Location = New-Object System.Drawing.Point(290, 293)
    $btnAddProfile.Size = New-Object System.Drawing.Size(100, 28)
    $dlgToggle.Controls.Add($btnAddProfile)

    $btnAddProfile.add_Click({
        if ($cmbAvailableProfs.SelectedItem) {
            $sel = $cmbAvailableProfs.SelectedItem.ToString()
            $lstSequence.Items.Add($sel) | Out-Null
        }
    })

    # Add Custom / New Toggle Sub-step
    $txtCustomStep = New-Object System.Windows.Forms.TextBox
    $txtCustomStep.Location = New-Object System.Drawing.Point(20, 335)
    $txtCustomStep.Size = New-Object System.Drawing.Size(260, 25)
    $dlgToggle.Controls.Add($txtCustomStep)

    $btnAddNewStep = New-Object System.Windows.Forms.Button
    $btnAddNewStep.Text = "+ Add New Name"
    $btnAddNewStep.Location = New-Object System.Drawing.Point(290, 333)
    $btnAddNewStep.Size = New-Object System.Drawing.Size(110, 28)
    $dlgToggle.Controls.Add($btnAddNewStep)

    $btnAddNewStep.add_Click({
        $cName = $txtCustomStep.Text.Trim()
        if ($cName) {
            $lstSequence.Items.Add($cName) | Out-Null
            $txtCustomStep.Clear()
        }
    })

    # OK / Cancel Buttons
    $btnSaveToggle = New-Object System.Windows.Forms.Button
    $btnSaveToggle.Text = "Save Toggle Cycle"
    $btnSaveToggle.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveToggle.Location = New-Object System.Drawing.Point(250, 395)
    $btnSaveToggle.Size = New-Object System.Drawing.Size(130, 32)
    $btnSaveToggle.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $btnSaveToggle.ForeColor = [System.Drawing.Color]::White
    $btnSaveToggle.FlatStyle = "Flat"
    $dlgToggle.Controls.Add($btnSaveToggle)

    $btnCancelToggle = New-Object System.Windows.Forms.Button
    $btnCancelToggle.Text = "Cancel"
    $btnCancelToggle.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancelToggle.Location = New-Object System.Drawing.Point(390, 395)
    $btnCancelToggle.Size = New-Object System.Drawing.Size(90, 32)
    $dlgToggle.Controls.Add($btnCancelToggle)
    $dlgToggle.AcceptButton = $btnSaveToggle
    $dlgToggle.CancelButton = $btnCancelToggle

    if ($dlgToggle.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $profObj.IsToggle = $chkIsToggle.Checked
        $newCycleArray = @()
        foreach ($item in $lstSequence.Items) {
            $newCycleArray += $item.ToString()
        }
        if ($chkIsToggle.Checked -and $newCycleArray.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Toggle mode requires at least one profile step in the cycle.", "Warning", "OK", "Warning")
            return
        }

        # Update note property
        if ($profObj.PSObject.Properties["ToggleCycle"]) {
            $profObj.ToggleCycle = $newCycleArray
        } else {
            $profObj | Add-Member -MemberType NoteProperty -Name "ToggleCycle" -Value $newCycleArray
        }

        # Ensure any sub-profiles in the cycle exist in Profiles list
        foreach ($stepName in $newCycleArray) {
            if (-not ($liveCfg.Profiles | Where-Object { $_.Name -eq $stepName })) {
                $subProf = [PSCustomObject]@{
                    Name      = $stepName
                    Label     = $stepName
                    Hidden    = $true
                    Devices   = (New-Object PSObject)
                    Plugs     = (New-Object PSObject)
                }
                $liveCfg.Profiles += $subProf
            }
        }

        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        [System.Windows.Forms.MessageBox]::Show("Toggle cycle configured with $($newCycleArray.Count) steps!", "Saved", "OK", "Information")
    }
})

# Rename Selected Profile Button Handler
$btnRenameProfile.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $oldName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $oldName } | Select-Object -First 1
    if (-not $profObj) { return }

    $dlgRename = New-Object System.Windows.Forms.Form
    $dlgRename.Text = "Rename Profile"
    $dlgRename.Size = New-Object System.Drawing.Size(430, 240)
    $dlgRename.StartPosition = "CenterParent"
    $dlgRename.FormBorderStyle = "FixedDialog"
    $dlgRename.MaximizeBox = $false
    $dlgRename.MinimizeBox = $false

    $lblRenName = New-Object System.Windows.Forms.Label
    $lblRenName.Text = "Profile Internal Name:"
    $lblRenName.Location = New-Object System.Drawing.Point(20, 15)
    $lblRenName.AutoSize = $true
    $dlgRename.Controls.Add($lblRenName)

    $txtRenName = New-Object System.Windows.Forms.TextBox
    $txtRenName.Text = $profObj.Name
    $txtRenName.Location = New-Object System.Drawing.Point(20, 38)
    $txtRenName.Size = New-Object System.Drawing.Size(370, 25)
    $dlgRename.Controls.Add($txtRenName)

    $lblRenLabel = New-Object System.Windows.Forms.Label
    $lblRenLabel.Text = "Display Label (displayed in tray menu & grid header):"
    $lblRenLabel.Location = New-Object System.Drawing.Point(20, 75)
    $lblRenLabel.AutoSize = $true
    $dlgRename.Controls.Add($lblRenLabel)

    $txtRenLabel = New-Object System.Windows.Forms.TextBox
    $txtRenLabel.Text = if ($profObj.Label) { $profObj.Label } else { $profObj.Name }
    $txtRenLabel.Location = New-Object System.Drawing.Point(20, 98)
    $txtRenLabel.Size = New-Object System.Drawing.Size(370, 25)
    $dlgRename.Controls.Add($txtRenLabel)

    $btnRenOk = New-Object System.Windows.Forms.Button
    $btnRenOk.Text = "Save Changes"
    $btnRenOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnRenOk.Location = New-Object System.Drawing.Point(190, 150)
    $btnRenOk.Size = New-Object System.Drawing.Size(110, 30)
    $btnRenOk.BackColor = [System.Drawing.Color]::FromArgb(79, 70, 229)
    $btnRenOk.ForeColor = [System.Drawing.Color]::White
    $btnRenOk.FlatStyle = "Flat"
    $dlgRename.Controls.Add($btnRenOk)

    $btnRenCancel = New-Object System.Windows.Forms.Button
    $btnRenCancel.Text = "Cancel"
    $btnRenCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnRenCancel.Location = New-Object System.Drawing.Point(310, 150)
    $btnRenCancel.Size = New-Object System.Drawing.Size(80, 30)
    $dlgRename.Controls.Add($btnRenCancel)
    $dlgRename.AcceptButton = $btnRenOk
    $dlgRename.CancelButton = $btnRenCancel

    if ($dlgRename.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $newName = $txtRenName.Text.Trim()
        $newLabel = $txtRenLabel.Text.Trim()

        if (-not $newName) {
            [System.Windows.Forms.MessageBox]::Show("Profile name cannot be empty.", "Error", "OK", "Warning")
            return
        }
        if (-not $newLabel) { $newLabel = $newName }

        # Check if renaming to a name that already exists (other than itself)
        if ($newName -ne $oldName -and ($liveCfg.Profiles | Where-Object { $_.Name -eq $newName })) {
            [System.Windows.Forms.MessageBox]::Show("A profile named '$newName' already exists.", "Duplicate Name", "OK", "Warning")
            return
        }

        # If name changed, rename associated native.json file if present
        if ($newName -ne $oldName) {
            $oldJson = Join-Path $configDir "$oldName.native.json"
            $newJson = Join-Path $configDir "$newName.native.json"
            if (Test-Path -LiteralPath $oldJson) {
                Move-Item -LiteralPath $oldJson -Destination $newJson -Force -ErrorAction SilentlyContinue
            }

            # Update references in any ToggleCycle lists across all profiles
            foreach ($p in $liveCfg.Profiles) {
                if ($p.ToggleCycle) {
                    $tc = @($p.ToggleCycle)
                    for ($k = 0; $k -lt $tc.Count; $k++) {
                        if ($tc[$k] -eq $oldName) { $tc[$k] = $newName }
                    }
                    $p.ToggleCycle = $tc
                }
            }
        }

        $profObj.Name = $newName
        $profObj.Label = $newLabel

        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        if ($refreshWebProfilesGrid) { & $refreshWebProfilesGrid }
        if ($updateWebTabDisplay) { & $updateWebTabDisplay }

        # Reselect updated item
        for ($i = 0; $i -lt $cmbProfiles.Items.Count; $i++) {
            if ($cmbProfiles.Items[$i].Name -eq $newName) {
                $cmbProfiles.SelectedIndex = $i
                break
            }
        }
        [System.Windows.Forms.MessageBox]::Show("Profile renamed successfully!", "Renamed", "OK", "Information")
    }
})

# Manage Menu Order & Separator Lines Button Handler
$btnManageOrder.add_Click({
    $liveCfg = Get-LiveConfig

    $dlgOrder = New-Object System.Windows.Forms.Form
    $dlgOrder.Text = "Manage Tray Menu Items & Separator Lines"
    $dlgOrder.Size = New-Object System.Drawing.Size(560, 520)
    $dlgOrder.StartPosition = "CenterParent"
    $dlgOrder.FormBorderStyle = "FixedDialog"
    $dlgOrder.MaximizeBox = $false
    $dlgOrder.MinimizeBox = $false

    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = "Organize how profiles and dividing lines appear in your System Tray context menu:"
    $lblHelp.Location = New-Object System.Drawing.Point(20, 15)
    $lblHelp.AutoSize = $true
    $dlgOrder.Controls.Add($lblHelp)

    $lstItems = New-Object System.Windows.Forms.ListBox
    $lstItems.Location = New-Object System.Drawing.Point(20, 45)
    $lstItems.Size = New-Object System.Drawing.Size(370, 360)
    $dlgOrder.Controls.Add($lstItems)

    # Function to reload list box with internal representations
    $workingList = [System.Collections.ArrayList]::new()
    foreach ($p in $liveCfg.Profiles) {
        $workingList.Add($p) | Out-Null
    }

    $renderList = {
        $lstItems.Items.Clear()
        foreach ($p in $workingList) {
            if ($p.Separator) {
                $lstItems.Items.Add("────── [ DIVIDER LINE ] ──────") | Out-Null
            } else {
                $lbl = if ($p.Label) { $p.Label } else { $p.Name }
                if ($p.Hidden) {
                    $lstItems.Items.Add("$lbl  (Hidden from tray)") | Out-Null
                } else {
                    $lstItems.Items.Add("$lbl") | Out-Null
                }
            }
        }
    }
    & $renderList

    # Buttons panel
    $btnUp = New-Object System.Windows.Forms.Button
    $btnUp.Text = "Move Up"
    $btnUp.Location = New-Object System.Drawing.Point(405, 45)
    $btnUp.Size = New-Object System.Drawing.Size(125, 30)
    $dlgOrder.Controls.Add($btnUp)

    $btnDown = New-Object System.Windows.Forms.Button
    $btnDown.Text = "Move Down"
    $btnDown.Location = New-Object System.Drawing.Point(405, 83)
    $btnDown.Size = New-Object System.Drawing.Size(125, 30)
    $dlgOrder.Controls.Add($btnDown)

    $btnAddLine = New-Object System.Windows.Forms.Button
    $btnAddLine.Text = "+ Add Line"
    $btnAddLine.Location = New-Object System.Drawing.Point(405, 128)
    $btnAddLine.Size = New-Object System.Drawing.Size(125, 30)
    $btnAddLine.BackColor = [System.Drawing.Color]::FromArgb(14, 116, 144)
    $btnAddLine.ForeColor = [System.Drawing.Color]::White
    $btnAddLine.FlatStyle = "Flat"
    $dlgOrder.Controls.Add($btnAddLine)

    $btnToggleHidden = New-Object System.Windows.Forms.Button
    $btnToggleHidden.Text = "Toggle Hide"
    $btnToggleHidden.Location = New-Object System.Drawing.Point(405, 166)
    $btnToggleHidden.Size = New-Object System.Drawing.Size(125, 30)
    $dlgOrder.Controls.Add($btnToggleHidden)

    $btnRemoveItem = New-Object System.Windows.Forms.Button
    $btnRemoveItem.Text = "Remove Line"
    $btnRemoveItem.Location = New-Object System.Drawing.Point(405, 204)
    $btnRemoveItem.Size = New-Object System.Drawing.Size(125, 30)
    $btnRemoveItem.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $btnRemoveItem.ForeColor = [System.Drawing.Color]::White
    $btnRemoveItem.FlatStyle = "Flat"
    $dlgOrder.Controls.Add($btnRemoveItem)

    $btnUp.add_Click({
        $idx = $lstItems.SelectedIndex
        if ($idx -gt 0) {
            $item = $workingList[$idx]
            $workingList.RemoveAt($idx)
            $workingList.Insert($idx - 1, $item)
            & $renderList
            $lstItems.SelectedIndex = $idx - 1
        }
    })

    $btnDown.add_Click({
        $idx = $lstItems.SelectedIndex
        if ($idx -ge 0 -and $idx -lt ($workingList.Count - 1)) {
            $item = $workingList[$idx]
            $workingList.RemoveAt($idx)
            $workingList.Insert($idx + 1, $item)
            & $renderList
            $lstItems.SelectedIndex = $idx + 1
        }
    })

    $btnAddLine.add_Click({
        $idx = $lstItems.SelectedIndex
        $sepObj = [PSCustomObject]@{ Separator = $true }
        if ($idx -ge 0) {
            $workingList.Insert($idx + 1, $sepObj)
            & $renderList
            $lstItems.SelectedIndex = $idx + 1
        } else {
            $workingList.Add($sepObj) | Out-Null
            & $renderList
            $lstItems.SelectedIndex = $workingList.Count - 1
        }
    })

    $btnToggleHidden.add_Click({
        $idx = $lstItems.SelectedIndex
        if ($idx -ge 0) {
            $target = $workingList[$idx]
            if (-not $target.Separator) {
                if ($target.PSObject.Properties["Hidden"]) {
                    $target.Hidden = -not [bool]$target.Hidden
                } else {
                    $target | Add-Member -MemberType NoteProperty -Name "Hidden" -Value $true
                }
                & $renderList
                $lstItems.SelectedIndex = $idx
            }
        }
    })

    $btnRemoveItem.add_Click({
        $idx = $lstItems.SelectedIndex
        if ($idx -ge 0) {
            $target = $workingList[$idx]
            if ($target.Separator) {
                $workingList.RemoveAt($idx)
                & $renderList
                if ($idx -lt $workingList.Count) { $lstItems.SelectedIndex = $idx }
                elseif ($workingList.Count -gt 0) { $lstItems.SelectedIndex = $workingList.Count - 1 }
            } else {
                [System.Windows.Forms.MessageBox]::Show("Profiles cannot be deleted from here. Use 'Delete' on the main toolbar to delete profiles. This button removes divider lines.", "Notice", "OK", "Information")
            }
        }
    })

    # Save & Cancel Buttons
    $btnSaveOrder = New-Object System.Windows.Forms.Button
    $btnSaveOrder.Text = "Save Menu Layout"
    $btnSaveOrder.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveOrder.Location = New-Object System.Drawing.Point(260, 428)
    $btnSaveOrder.Size = New-Object System.Drawing.Size(130, 32)
    $btnSaveOrder.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $btnSaveOrder.ForeColor = [System.Drawing.Color]::White
    $btnSaveOrder.FlatStyle = "Flat"
    $dlgOrder.Controls.Add($btnSaveOrder)

    $btnCancelOrder = New-Object System.Windows.Forms.Button
    $btnCancelOrder.Text = "Cancel"
    $btnCancelOrder.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancelOrder.Location = New-Object System.Drawing.Point(400, 428)
    $btnCancelOrder.Size = New-Object System.Drawing.Size(90, 32)
    $dlgOrder.Controls.Add($btnCancelOrder)
    $dlgOrder.AcceptButton = $btnSaveOrder
    $dlgOrder.CancelButton = $btnCancelOrder

    if ($dlgOrder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $liveCfg.Profiles = @($workingList.ToArray())
        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        if ($refreshWebProfilesGrid) { & $refreshWebProfilesGrid }
        if ($updateWebTabDisplay) { & $updateWebTabDisplay }
        [System.Windows.Forms.MessageBox]::Show("Menu order and divider lines updated successfully!", "Saved", "OK", "Information")
    }
})

# Audio Output Device Assignment Handler
$btnAudioSelect.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a target profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $targetProfName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1
    if (-not $profObj) { return }

    $dlgAudio = New-Object System.Windows.Forms.Form
    $dlgAudio.Text = "Assign Audio Output Device - $targetProfName"
    $dlgAudio.Size = New-Object System.Drawing.Size(460, 270)
    $dlgAudio.StartPosition = "CenterParent"
    $dlgAudio.FormBorderStyle = "FixedDialog"
    $dlgAudio.MaximizeBox = $false
    $dlgAudio.MinimizeBox = $false

    $lblAud = New-Object System.Windows.Forms.Label
    $lblAud.Text = "Select the Windows audio playback device to automatically activate with '$targetProfName':"
    $lblAud.Location = New-Object System.Drawing.Point(20, 15)
    $lblAud.Size = New-Object System.Drawing.Size(410, 35)
    $dlgAudio.Controls.Add($lblAud)

    $cmbAudList = New-Object System.Windows.Forms.ComboBox
    $cmbAudList.DropDownStyle = "DropDownList"
    $cmbAudList.Location = New-Object System.Drawing.Point(20, 55)
    $cmbAudList.Size = New-Object System.Drawing.Size(400, 25)
    $cmbAudList.Items.Add("[None - Do not switch audio]") | Out-Null

    $endpoints = Get-ActiveAudioEndpoints
    $currentAssigned = if ($profObj.AudioDevice) { $profObj.AudioDevice } else { "" }
    $liveDefault = Get-LiveDefaultAudioName

    $selectedIndex = 0
    for ($i = 0; $i -lt $endpoints.Count; $i++) {
        $ep = $endpoints[$i]
        $cmbAudList.Items.Add($ep.Display) | Out-Null
        if ($currentAssigned -and ($ep.Display -eq $currentAssigned -or $ep.Name -eq $currentAssigned -or $ep.Id -eq $currentAssigned)) {
            $selectedIndex = $i + 1
        }
    }
    $cmbAudList.SelectedIndex = $selectedIndex
    $dlgAudio.Controls.Add($cmbAudList)

    # Capture Current Playing Endpoint button
    $btnCaptureCurAudio = New-Object System.Windows.Forms.Button
    $btnCaptureCurAudio.Text = "Capture Currently Active Audio ($liveDefault)"
    $btnCaptureCurAudio.Location = New-Object System.Drawing.Point(20, 92)
    $btnCaptureCurAudio.Size = New-Object System.Drawing.Size(400, 28)
    $btnCaptureCurAudio.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnCaptureCurAudio.FlatStyle = "Flat"
    $dlgAudio.Controls.Add($btnCaptureCurAudio)

    $btnCaptureCurAudio.add_Click({
        if ($liveDefault) {
            for ($k = 0; $k -lt $cmbAudList.Items.Count; $k++) {
                if ($cmbAudList.Items[$k].ToString() -eq $liveDefault) {
                    $cmbAudList.SelectedIndex = $k
                    break
                }
            }
        }
    })

    # Save and Cancel
    $btnSaveAud = New-Object System.Windows.Forms.Button
    $btnSaveAud.Text = "Save Audio"
    $btnSaveAud.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveAud.Location = New-Object System.Drawing.Point(220, 160)
    $btnSaveAud.Size = New-Object System.Drawing.Size(100, 32)
    $btnSaveAud.BackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
    $btnSaveAud.ForeColor = [System.Drawing.Color]::White
    $btnSaveAud.FlatStyle = "Flat"
    $dlgAudio.Controls.Add($btnSaveAud)

    $btnCancelAud = New-Object System.Windows.Forms.Button
    $btnCancelAud.Text = "Cancel"
    $btnCancelAud.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancelAud.Location = New-Object System.Drawing.Point(330, 160)
    $btnCancelAud.Size = New-Object System.Drawing.Size(90, 32)
    $dlgAudio.Controls.Add($btnCancelAud)
    $dlgAudio.AcceptButton = $btnSaveAud
    $dlgAudio.CancelButton = $btnCancelAud

    if ($dlgAudio.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $assigned = ""
        if ($cmbAudList.SelectedIndex -gt 0) {
            $assigned = $cmbAudList.SelectedItem.ToString()
        }

        if ($profObj.PSObject.Properties["AudioDevice"]) {
            $profObj.AudioDevice = $assigned
        } else {
            $profObj | Add-Member -MemberType NoteProperty -Name "AudioDevice" -Value $assigned
        }

        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        $msg = if ($assigned) { "Profile '$targetProfName' will now switch audio to:`n$assigned" } else { "Audio switching removed for '$targetProfName'." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Audio Saved", "OK", "Information")
    }
})

# Launch Application Assignment Handler
$btnAppSelect.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a target profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $targetProfName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1
    if (-not $profObj) { return }

    $dlgApp = New-Object System.Windows.Forms.Form
    $dlgApp.Text = "Launch Application On Switch - $targetProfName"
    $dlgApp.Size = New-Object System.Drawing.Size(560, 360)
    $dlgApp.StartPosition = "CenterParent"
    $dlgApp.FormBorderStyle = "FixedDialog"
    $dlgApp.MaximizeBox = $false
    $dlgApp.MinimizeBox = $false

    $lblAppDesc = New-Object System.Windows.Forms.Label
    $lblAppDesc.Text = "Optionally launch a game client, dashboard, or script when switching to '$targetProfName' (e.g. Steam Big Picture mode, SimHub, or custom tool):"
    $lblAppDesc.Location = New-Object System.Drawing.Point(20, 15)
    $lblAppDesc.Size = New-Object System.Drawing.Size(505, 35)
    $dlgApp.Controls.Add($lblAppDesc)

    $lblAppPath = New-Object System.Windows.Forms.Label
    $lblAppPath.Text = "Executable / Script Path:"
    $lblAppPath.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblAppPath.Location = New-Object System.Drawing.Point(20, 58)
    $lblAppPath.Size = New-Object System.Drawing.Size(200, 20)
    $dlgApp.Controls.Add($lblAppPath)

    $txtAppPath = New-Object System.Windows.Forms.TextBox
    $txtAppPath.Location = New-Object System.Drawing.Point(20, 80)
    $txtAppPath.Size = New-Object System.Drawing.Size(415, 25)
    $txtAppPath.Text = if ($profObj.LaunchApp) { $profObj.LaunchApp } else { "" }
    $dlgApp.Controls.Add($txtAppPath)

    $btnBrowseApp = New-Object System.Windows.Forms.Button
    $btnBrowseApp.Text = "Browse..."
    $btnBrowseApp.Location = New-Object System.Drawing.Point(445, 78)
    $btnBrowseApp.Size = New-Object System.Drawing.Size(80, 29)
    $dlgApp.Controls.Add($btnBrowseApp)

    $btnBrowseApp.add_Click({
        $openDlg = New-Object System.Windows.Forms.OpenFileDialog
        $openDlg.Title = "Select Application or Script to Launch"
        $openDlg.Filter = "Programs & Scripts (*.exe;*.bat;*.cmd;*.ps1;*.vbs;*.lnk)|*.exe;*.bat;*.cmd;*.ps1;*.vbs;*.lnk|All Files (*.*)|*.*"
        if ($openDlg.ShowDialog($dlgApp) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtAppPath.Text = $openDlg.FileName
        }
    })

    $lblAppArgs = New-Object System.Windows.Forms.Label
    $lblAppArgs.Text = "Arguments (Optional):"
    $lblAppArgs.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblAppArgs.Location = New-Object System.Drawing.Point(20, 115)
    $lblAppArgs.Size = New-Object System.Drawing.Size(200, 20)
    $dlgApp.Controls.Add($lblAppArgs)

    $txtAppArgs = New-Object System.Windows.Forms.TextBox
    $txtAppArgs.Location = New-Object System.Drawing.Point(20, 137)
    $txtAppArgs.Size = New-Object System.Drawing.Size(505, 25)
    $txtAppArgs.Text = if ($profObj.LaunchAppArgs) { $profObj.LaunchAppArgs } else { "" }
    $dlgApp.Controls.Add($txtAppArgs)

    # Preset Quick-Buttons (Steam Big Picture, etc.)
    $lblPresets = New-Object System.Windows.Forms.Label
    $lblPresets.Text = "Quick Presets:"
    $lblPresets.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5, [System.Drawing.FontStyle]::Bold)
    $lblPresets.Location = New-Object System.Drawing.Point(20, 175)
    $lblPresets.Size = New-Object System.Drawing.Size(100, 20)
    $dlgApp.Controls.Add($lblPresets)

    $steamExe = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamExe
    if (-not $steamExe -or -not (Test-Path -LiteralPath $steamExe)) {
        if (Test-Path "C:\Program Files (x86)\Steam\steam.exe") { $steamExe = "C:\Program Files (x86)\Steam\steam.exe" }
        elseif (Test-Path "D:\games\steam\steam.exe") { $steamExe = "D:\games\steam\steam.exe" }
    }

    $btnSteamBP = New-Object System.Windows.Forms.Button
    $btnSteamBP.Text = "Steam Big Picture"
    $btnSteamBP.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $btnSteamBP.Location = New-Object System.Drawing.Point(20, 198)
    $btnSteamBP.Size = New-Object System.Drawing.Size(155, 30)
    $btnSteamBP.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnSteamBP.FlatStyle = "Flat"
    $dlgApp.Controls.Add($btnSteamBP)

    $btnSteamBP.add_Click({
        if ($steamExe) {
            $txtAppPath.Text = $steamExe
            $txtAppArgs.Text = "-bigpicture"
        } else {
            [System.Windows.Forms.MessageBox]::Show("Steam installation not automatically found in registry. Please browse to steam.exe manually.", "Steam Not Found", "OK", "Information")
        }
    })

    $btnClearApp = New-Object System.Windows.Forms.Button
    $btnClearApp.Text = "Clear (No App)"
    $btnClearApp.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    $btnClearApp.Location = New-Object System.Drawing.Point(185, 198)
    $btnClearApp.Size = New-Object System.Drawing.Size(120, 30)
    $btnClearApp.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnClearApp.FlatStyle = "Flat"
    $dlgApp.Controls.Add($btnClearApp)

    $btnClearApp.add_Click({
        $txtAppPath.Text = ""
        $txtAppArgs.Text = ""
    })

    # Save and Cancel
    $btnSaveApp = New-Object System.Windows.Forms.Button
    $btnSaveApp.Text = "Save App Setting"
    $btnSaveApp.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveApp.Location = New-Object System.Drawing.Point(270, 260)
    $btnSaveApp.Size = New-Object System.Drawing.Size(140, 34)
    $btnSaveApp.BackColor = [System.Drawing.Color]::FromArgb(13, 148, 136)
    $btnSaveApp.ForeColor = [System.Drawing.Color]::White
    $btnSaveApp.FlatStyle = "Flat"
    $dlgApp.Controls.Add($btnSaveApp)

    $btnCancelApp = New-Object System.Windows.Forms.Button
    $btnCancelApp.Text = "Cancel"
    $btnCancelApp.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancelApp.Location = New-Object System.Drawing.Point(420, 260)
    $btnCancelApp.Size = New-Object System.Drawing.Size(105, 34)
    $dlgApp.Controls.Add($btnCancelApp)
    $dlgApp.AcceptButton = $btnSaveApp
    $dlgApp.CancelButton = $btnCancelApp

    if ($dlgApp.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $chosenApp = $txtAppPath.Text.Trim()
        $chosenArgs = $txtAppArgs.Text.Trim()

        if ($profObj.PSObject.Properties["LaunchApp"]) {
            $profObj.LaunchApp = $chosenApp
        } else {
            $profObj | Add-Member -MemberType NoteProperty -Name "LaunchApp" -Value $chosenApp
        }

        if ($profObj.PSObject.Properties["LaunchAppArgs"]) {
            $profObj.LaunchAppArgs = $chosenArgs
        } else {
            $profObj | Add-Member -MemberType NoteProperty -Name "LaunchAppArgs" -Value $chosenArgs
        }

        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        $msg = if ($chosenApp) { "Profile '$targetProfName' will now launch:`n$chosenApp $chosenArgs" } else { "Application launch removed for '$targetProfName'." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Launch Settings Saved", "OK", "Information")
    }
})

# Wallpaper Assignment & Multi-Monitor Layout Preview Handler
$btnWallpapers.add_Click({
    if (-not $cmbProfiles.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a target profile from the dropdown first.", "No Profile Selected", "OK", "Warning")
        return
    }

    $selItem = $cmbProfiles.SelectedItem
    $targetProfName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }
    $liveCfg = Get-LiveConfig
    $profObj = $liveCfg.Profiles | Where-Object { $_.Name -eq $targetProfName } | Select-Object -First 1
    if (-not $profObj) { return }

    # Query monitors: First attempt to load exact layout from Profile's captured native.json.
    # If not present or empty, fallback to currently active desktop monitors.
    $profileNativeJson = Join-Path $configDir "$targetProfName.native.json"
    $mons = [System.Collections.ArrayList]::new()

    if (Test-Path -LiteralPath $profileNativeJson) {
        try {
            $parsedJson = Get-Content -LiteralPath $profileNativeJson -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsedJson.Monitors -and $parsedJson.Monitors.Count -gt 0) {
                # Sort monitors left-to-right (by PositionX, then PositionY)
                $sortedMonList = $parsedJson.Monitors | Sort-Object PositionX, PositionY
                $idx = 0
                foreach ($m in $sortedMonList) {
                    $mons.Add([PSCustomObject]@{
                        Index            = $idx
                        Name             = $m.Name
                        Left             = [int]$m.PositionX
                        Top              = [int]$m.PositionY
                        Right            = [int]($m.PositionX + $m.Width)
                        Bottom           = [int]($m.PositionY + $m.Height)
                        Width            = [int]$m.Width
                        Height           = [int]$m.Height
                        Path             = ""
                        CurrentWallpaper = ""
                    }) | Out-Null
                    $idx++
                }
            }
        } catch {}
    }

    # Fallback to active desktop monitors if no native.json available
    if ($mons.Count -eq 0) {
        $activeMons = [DesktopWallpaperNative]::GetActiveMonitors()
        if ($activeMons -and $activeMons.Count -gt 0) {
            foreach ($am in $activeMons) {
                $mons.Add([PSCustomObject]@{
                    Index            = $am.Index
                    Name             = "Display"
                    Left             = $am.Left
                    Top              = $am.Top
                    Right            = $am.Right
                    Bottom           = $am.Bottom
                    Width            = ($am.Right - $am.Left)
                    Height           = ($am.Bottom - $am.Top)
                    Path             = $am.Path
                    CurrentWallpaper = $am.CurrentWallpaper
                }) | Out-Null
            }
        }
    }

    if ($mons.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Could not resolve monitor layout for profile '$targetProfName'. Please snapshot layout first or ensure displays are connected.", "Monitor Query Error", "OK", "Warning")
        return
    }

    $dlgWall = New-Object System.Windows.Forms.Form
    $dlgWall.Text = "Desktop Wallpapers, Positioning & Adjustments - $targetProfName"
    $dlgWall.Size = New-Object System.Drawing.Size(920, 780)
    $dlgWall.StartPosition = "CenterParent"
    $dlgWall.FormBorderStyle = "FixedDialog"
    $dlgWall.MaximizeBox = $false
    $dlgWall.MinimizeBox = $false
    $dlgWall.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

    # Top Checkbox: Allow DeskShift to manage desktop wallpapers for this profile
    $chkEnableWall = New-Object System.Windows.Forms.CheckBox
    $chkEnableWall.Text = "Allow DeskShift to manage Desktop Wallpapers for this profile (Optional)"
    $chkEnableWall.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10.0, [System.Drawing.FontStyle]::Bold)
    $chkEnableWall.Location = New-Object System.Drawing.Point(20, 15)
    $chkEnableWall.Size = New-Object System.Drawing.Size(600, 26)
    $isWallEnabled = if ($profObj.Wallpapers -and ($null -ne $profObj.Wallpapers.Enabled)) { [bool]$profObj.Wallpapers.Enabled } else { $false }
    $chkEnableWall.Checked = $isWallEnabled
    $dlgWall.Controls.Add($chkEnableWall)

    # Visual Preview Box (DisplayFusion-style)
    $grpPreview = New-Object System.Windows.Forms.GroupBox
    $grpPreview.Text = "Wallpaper Preview & Monitor Layout (True Aspect Ratio)"
    $grpPreview.Location = New-Object System.Drawing.Point(20, 48)
    $grpPreview.Size = New-Object System.Drawing.Size(865, 200)
    $grpPreview.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $dlgWall.Controls.Add($grpPreview)

    $pnlCanvas = New-Object System.Windows.Forms.Panel
    $pnlCanvas.Location = New-Object System.Drawing.Point(15, 22)
    $pnlCanvas.Size = New-Object System.Drawing.Size(835, 165)
    $pnlCanvas.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $grpPreview.Controls.Add($pnlCanvas)

    # Main Settings Tabs (Source & Mode, Adjustments & Colors)
    $wallTabControl = New-Object System.Windows.Forms.TabControl
    $wallTabControl.Location = New-Object System.Drawing.Point(20, 255)
    $wallTabControl.Size = New-Object System.Drawing.Size(865, 415)
    $dlgWall.Controls.Add($wallTabControl)

    # TAB 1: Source & Sizing
    $tabSource = New-Object System.Windows.Forms.TabPage("Wallpaper Source & Sizing")
    $tabSource.BackColor = [System.Drawing.Color]::White

    $lblSizing = New-Object System.Windows.Forms.Label
    $lblSizing.Text = "Sizing / Scaling Mode:"
    $lblSizing.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblSizing.Location = New-Object System.Drawing.Point(20, 20)
    $lblSizing.Size = New-Object System.Drawing.Size(160, 20)
    $tabSource.Controls.Add($lblSizing)

    $cmbSizing = New-Object System.Windows.Forms.ComboBox
    $cmbSizing.DropDownStyle = "DropDownList"
    $cmbSizing.Location = New-Object System.Drawing.Point(20, 42)
    $cmbSizing.Size = New-Object System.Drawing.Size(320, 25)
    $cmbSizing.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    $cmbSizing.Items.AddRange(@(
        "Fill (Fit and Clip Edges)",
        "Fit (Fit Best and Maintain Aspect Ratio)",
        "Stretch (Stretch to Fit Entire Screen)",
        "Center (Center Image Unscaled)",
        "Tile (Repeat Across Screen)",
        "Span (Span Across All Monitors)"
    ))

    $curPos = if ($profObj.Wallpapers -and $profObj.Wallpapers.Position) { $profObj.Wallpapers.Position } else { "Fill" }
    switch ($curPos) {
        "Fill" { $cmbSizing.SelectedIndex = 0 }
        "Fit" { $cmbSizing.SelectedIndex = 1 }
        "Stretch" { $cmbSizing.SelectedIndex = 2 }
        "Center" { $cmbSizing.SelectedIndex = 3 }
        "Tile" { $cmbSizing.SelectedIndex = 4 }
        "Span" { $cmbSizing.SelectedIndex = 5 }
        default { $cmbSizing.SelectedIndex = 0 }
    }
    $tabSource.Controls.Add($cmbSizing)

    # Monitor Selector
    $lblMonSelect = New-Object System.Windows.Forms.Label
    $lblMonSelect.Text = "Select Monitor to Configure:"
    $lblMonSelect.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblMonSelect.Location = New-Object System.Drawing.Point(20, 80)
    $lblMonSelect.Size = New-Object System.Drawing.Size(200, 20)
    $tabSource.Controls.Add($lblMonSelect)

    $cmbMonitorPick = New-Object System.Windows.Forms.ComboBox
    $cmbMonitorPick.DropDownStyle = "DropDownList"
    $cmbMonitorPick.Location = New-Object System.Drawing.Point(20, 102)
    $cmbMonitorPick.Size = New-Object System.Drawing.Size(360, 25)
    $cmbMonitorPick.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    for ($m = 0; $m -lt $mons.Count; $m++) {
        $mon = $mons[$m]
        $cmbMonitorPick.Items.Add("Monitor $($m + 1): $($mon.Name) ($($mon.Width)x$($mon.Height)) at ($($mon.Left), $($mon.Top))") | Out-Null
    }
    if ($cmbMonitorPick.Items.Count -gt 0) { $cmbMonitorPick.SelectedIndex = 0 }
    $tabSource.Controls.Add($cmbMonitorPick)

    # Local state for wallpaper image assignments: [int] -> [string]
    $wallState = [ordered]@{}
    if ($profObj.Wallpapers -and $profObj.Wallpapers.Monitors) {
        foreach ($prop in $profObj.Wallpapers.Monitors.PSObject.Properties) {
            $wallState[$prop.Name] = $prop.Value
        }
    }
    $spanImageState = if ($profObj.Wallpapers -and $profObj.Wallpapers.SpanImage) { $profObj.Wallpapers.SpanImage } else { "" }

    # Adjustments state: [string] -> hashtable of @{ OffsetX, OffsetY, FlipH, FlipV, BgColor }
    $adjState = [ordered]@{}
    if ($profObj.Wallpapers -and $profObj.Wallpapers.Adjustments) {
        foreach ($prop in $profObj.Wallpapers.Adjustments.PSObject.Properties) {
            $val = $prop.Value
            $adjState[$prop.Name] = [ordered]@{
                OffsetX = if ($val.PSObject.Properties["OffsetX"]) { [int]$val.OffsetX } else { 0 }
                OffsetY = if ($val.PSObject.Properties["OffsetY"]) { [int]$val.OffsetY } else { 0 }
                FlipH   = if ($val.PSObject.Properties["FlipH"]) { [bool]$val.FlipH } else { $false }
                FlipV   = if ($val.PSObject.Properties["FlipV"]) { [bool]$val.FlipV } else { $false }
                BgColor = if ($val.PSObject.Properties["BgColor"]) { $val.BgColor } else { "#000000" }
            }
        }
    }

    # Ensure all monitors have adjustment entries
    for ($m = 1; $m -le $mons.Count; $m++) {
        $k = "$m"
        if (-not $adjState.Contains($k)) {
            $adjState[$k] = [ordered]@{
                OffsetX = 0
                OffsetY = 0
                FlipH   = $false
                FlipV   = $false
                BgColor = "#000000"
            }
        }
    }

    # Image path box and browse
    $lblImgPath = New-Object System.Windows.Forms.Label
    $lblImgPath.Text = "Wallpaper Image Source:"
    $lblImgPath.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $lblImgPath.Location = New-Object System.Drawing.Point(20, 145)
    $lblImgPath.Size = New-Object System.Drawing.Size(350, 20)
    $tabSource.Controls.Add($lblImgPath)

    $txtImgPath = New-Object System.Windows.Forms.TextBox
    $txtImgPath.Location = New-Object System.Drawing.Point(20, 168)
    $txtImgPath.Size = New-Object System.Drawing.Size(710, 25)
    $txtImgPath.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    $tabSource.Controls.Add($txtImgPath)

    $btnBrowseImg = New-Object System.Windows.Forms.Button
    $btnBrowseImg.Text = "Browse..."
    $btnBrowseImg.Location = New-Object System.Drawing.Point(740, 166)
    $btnBrowseImg.Size = New-Object System.Drawing.Size(95, 29)
    $btnBrowseImg.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnBrowseImg.FlatStyle = "Flat"
    $tabSource.Controls.Add($btnBrowseImg)

    $btnClearImg = New-Object System.Windows.Forms.Button
    $btnClearImg.Text = "Clear"
    $btnClearImg.Location = New-Object System.Drawing.Point(20, 205)
    $btnClearImg.Size = New-Object System.Drawing.Size(75, 28)
    $btnClearImg.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnClearImg.FlatStyle = "Flat"
    $tabSource.Controls.Add($btnClearImg)

    $btnCopyAll = New-Object System.Windows.Forms.Button
    $btnCopyAll.Text = "Use This Image On All Monitors"
    $btnCopyAll.Location = New-Object System.Drawing.Point(105, 205)
    $btnCopyAll.Size = New-Object System.Drawing.Size(210, 28)
    $btnCopyAll.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnCopyAll.FlatStyle = "Flat"
    $tabSource.Controls.Add($btnCopyAll)

    $wallTabControl.TabPages.Add($tabSource)

    # TAB 2: Position Adjustments & Offsets (Start Bar, Alignment, Flips, Background)
    $tabAdjust = New-Object System.Windows.Forms.TabPage("Position Offsets & Adjustments")
    $tabAdjust.BackColor = [System.Drawing.Color]::White

    $lblAdjHelp = New-Object System.Windows.Forms.Label
    $lblAdjHelp.Text = "Offset image pixels to account for the Windows Taskbar / Dock, flip orientation, or set background fill color:"
    $lblAdjHelp.Location = New-Object System.Drawing.Point(20, 15)
    $lblAdjHelp.Size = New-Object System.Drawing.Size(800, 22)
    $lblAdjHelp.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $tabAdjust.Controls.Add($lblAdjHelp)

    # Horizontal Offset
    $lblOffX = New-Object System.Windows.Forms.Label
    $lblOffX.Text = "Move Horizontal (pixels):"
    $lblOffX.Location = New-Object System.Drawing.Point(20, 48)
    $lblOffX.Size = New-Object System.Drawing.Size(180, 20)
    $tabAdjust.Controls.Add($lblOffX)

    $numOffX = New-Object System.Windows.Forms.NumericUpDown
    $numOffX.Minimum = -2000
    $numOffX.Maximum = 2000
    $numOffX.Value = 0
    $numOffX.Location = New-Object System.Drawing.Point(20, 70)
    $numOffX.Size = New-Object System.Drawing.Size(120, 25)
    $tabAdjust.Controls.Add($numOffX)

    # Vertical Offset (Start bar offset)
    $lblOffY = New-Object System.Windows.Forms.Label
    $lblOffY.Text = "Move Vertical (pixels - e.g. taskbar offset):"
    $lblOffY.Location = New-Object System.Drawing.Point(220, 48)
    $lblOffY.Size = New-Object System.Drawing.Size(260, 20)
    $tabAdjust.Controls.Add($lblOffY)

    $numOffY = New-Object System.Windows.Forms.NumericUpDown
    $numOffY.Minimum = -2000
    $numOffY.Maximum = 2000
    $numOffY.Value = 0
    $numOffY.Location = New-Object System.Drawing.Point(220, 70)
    $numOffY.Size = New-Object System.Drawing.Size(120, 25)
    $tabAdjust.Controls.Add($numOffY)

    # Quick taskbar buttons
    $btnTaskbarDown48 = New-Object System.Windows.Forms.Button
    $btnTaskbarDown48.Text = "Offset +48px (Bottom Taskbar)"
    $btnTaskbarDown48.Location = New-Object System.Drawing.Point(355, 68)
    $btnTaskbarDown48.Size = New-Object System.Drawing.Size(200, 28)
    $btnTaskbarDown48.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnTaskbarDown48.FlatStyle = "Flat"
    $tabAdjust.Controls.Add($btnTaskbarDown48)

    $btnTaskbarUp48 = New-Object System.Windows.Forms.Button
    $btnTaskbarUp48.Text = "Offset -48px (Top Taskbar)"
    $btnTaskbarUp48.Location = New-Object System.Drawing.Point(565, 68)
    $btnTaskbarUp48.Size = New-Object System.Drawing.Size(180, 28)
    $btnTaskbarUp48.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnTaskbarUp48.FlatStyle = "Flat"
    $tabAdjust.Controls.Add($btnTaskbarUp48)

    $btnTaskbarDown48.add_Click({
        $numOffY.Value = 48
    })

    $btnTaskbarUp48.add_Click({
        $numOffY.Value = -48
    })

    # Image Flipping Checkboxes
    $chkFlipH = New-Object System.Windows.Forms.CheckBox
    $chkFlipH.Text = "Flip image horizontally (mirrored left-to-right)"
    $chkFlipH.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    $chkFlipH.Location = New-Object System.Drawing.Point(20, 115)
    $chkFlipH.Size = New-Object System.Drawing.Size(320, 24)
    $tabAdjust.Controls.Add($chkFlipH)

    $chkFlipV = New-Object System.Windows.Forms.CheckBox
    $chkFlipV.Text = "Flip image vertically (upside down)"
    $chkFlipV.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)
    $chkFlipV.Location = New-Object System.Drawing.Point(20, 145)
    $chkFlipV.Size = New-Object System.Drawing.Size(320, 24)
    $tabAdjust.Controls.Add($chkFlipV)

    # Background Fill Color
    $lblBgColor = New-Object System.Windows.Forms.Label
    $lblBgColor.Text = "Letterbox / Border Background Color:"
    $lblBgColor.Location = New-Object System.Drawing.Point(20, 185)
    $lblBgColor.Size = New-Object System.Drawing.Size(260, 20)
    $tabAdjust.Controls.Add($lblBgColor)

    $pnlColorPreview = New-Object System.Windows.Forms.Panel
    $pnlColorPreview.Location = New-Object System.Drawing.Point(20, 210)
    $pnlColorPreview.Size = New-Object System.Drawing.Size(40, 28)
    $pnlColorPreview.BorderStyle = "FixedSingle"
    $pnlColorPreview.BackColor = [System.Drawing.Color]::Black
    $tabAdjust.Controls.Add($pnlColorPreview)

    $txtBgColorHex = New-Object System.Windows.Forms.TextBox
    $txtBgColorHex.Location = New-Object System.Drawing.Point(70, 210)
    $txtBgColorHex.Size = New-Object System.Drawing.Size(90, 25)
    $txtBgColorHex.Text = "#000000"
    $tabAdjust.Controls.Add($txtBgColorHex)

    $btnPickColor = New-Object System.Windows.Forms.Button
    $btnPickColor.Text = "Choose Color..."
    $btnPickColor.Location = New-Object System.Drawing.Point(170, 208)
    $btnPickColor.Size = New-Object System.Drawing.Size(120, 29)
    $btnPickColor.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $btnPickColor.FlatStyle = "Flat"
    $tabAdjust.Controls.Add($btnPickColor)

    $btnPickColor.add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog
        if ($cd.ShowDialog($dlgWall) -eq [System.Windows.Forms.DialogResult]::OK) {
            $hex = "#{0:X2}{1:X2}{2:X2}" -f $cd.Color.R, $cd.Color.G, $cd.Color.B
            $txtBgColorHex.Text = $hex
            $pnlColorPreview.BackColor = $cd.Color
            $key = & $getCurMonKey
            $adjState[$key].BgColor = $hex
            $pnlCanvas.Invalidate()
        }
    })

    $txtBgColorHex.add_TextChanged({
        try {
            $c = [System.Drawing.ColorTranslator]::FromHtml($txtBgColorHex.Text.Trim())
            $pnlColorPreview.BackColor = $c
            $key = & $getCurMonKey
            $adjState[$key].BgColor = $txtBgColorHex.Text.Trim()
            $pnlCanvas.Invalidate()
        } catch {}
    })

    $numOffX.add_ValueChanged({
        $key = & $getCurMonKey
        $adjState[$key].OffsetX = [int]$numOffX.Value
        $pnlCanvas.Invalidate()
    })

    $numOffY.add_ValueChanged({
        $key = & $getCurMonKey
        $adjState[$key].OffsetY = [int]$numOffY.Value
        $pnlCanvas.Invalidate()
    })

    $chkFlipH.add_CheckedChanged({
        $key = & $getCurMonKey
        $adjState[$key].FlipH = [bool]$chkFlipH.Checked
        $pnlCanvas.Invalidate()
    })

    $chkFlipV.add_CheckedChanged({
        $key = & $getCurMonKey
        $adjState[$key].FlipV = [bool]$chkFlipV.Checked
        $pnlCanvas.Invalidate()
    })

    $wallTabControl.TabPages.Add($tabAdjust)

    # Current monitor index helper
    $getCurMonKey = {
        return "$($cmbMonitorPick.SelectedIndex + 1)"
    }

    $updateSelectedMonitorField = {
        $key = & $getCurMonKey
        if ($cmbSizing.SelectedIndex -eq 5) { # Span
            $lblImgPath.Text = "Span Wallpaper Image Source (Across all monitors):"
            $txtImgPath.Text = $spanImageState
            $cmbMonitorPick.Enabled = $false
        } else {
            $lblImgPath.Text = "Wallpaper Image Source for Monitor ${key}:"
            $cmbMonitorPick.Enabled = $true
            if ($wallState.Contains($key)) {
                $txtImgPath.Text = $wallState[$key]
            } else {
                $mIdx = $cmbMonitorPick.SelectedIndex
                if ($mIdx -ge 0 -and $mIdx -lt $mons.Count) {
                    $txtImgPath.Text = $mons[$mIdx].CurrentWallpaper
                } else {
                    $txtImgPath.Text = ""
                }
            }
        }

        # Load adjustment values for this monitor
        if ($adjState.Contains($key)) {
            $adj = $adjState[$key]
            $numOffX.Value = [int]$adj.OffsetX
            $numOffY.Value = [int]$adj.OffsetY
            $chkFlipH.Checked = [bool]$adj.FlipH
            $chkFlipV.Checked = [bool]$adj.FlipV
            $txtBgColorHex.Text = $adj.BgColor
            try { $pnlColorPreview.BackColor = [System.Drawing.ColorTranslator]::FromHtml($adj.BgColor) } catch {}
        }
        $pnlCanvas.Invalidate()
    }

    $cmbMonitorPick.add_SelectedIndexChanged({
        & $updateSelectedMonitorField
    })

    $cmbSizing.add_SelectedIndexChanged({
        & $updateSelectedMonitorField
    })

    $txtImgPath.add_TextChanged({
        $key = & $getCurMonKey
        if ($cmbSizing.SelectedIndex -eq 5) {
            $script:spanImageState = $txtImgPath.Text.Trim()
        } else {
            $wallState[$key] = $txtImgPath.Text.Trim()
        }
        $pnlCanvas.Invalidate()
    })

    $btnBrowseImg.add_Click({
        $openDlg = New-Object System.Windows.Forms.OpenFileDialog
        $openDlg.Title = "Select Desktop Wallpaper Image"
        $openDlg.Filter = "Image Files (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp|All Files (*.*)|*.*"
        if ($openDlg.ShowDialog($dlgWall) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtImgPath.Text = $openDlg.FileName
        }
    })

    $btnClearImg.add_Click({
        $txtImgPath.Text = ""
    })

    $btnCopyAll.add_Click({
        $val = $txtImgPath.Text.Trim()
        for ($m = 1; $m -le $mons.Count; $m++) {
            $wallState["$m"] = $val
        }
        $pnlCanvas.Invalidate()
        [System.Windows.Forms.MessageBox]::Show("Applied image to all $($mons.Count) monitors.", "Applied", "OK", "Information")
    })

    # Render Proportional Monitor Preview Canvas with True Aspect Ratio and Image Adjustments
    $pnlCanvas.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

        if ($mons.Count -eq 0) { return }

        # Calculate bounding rectangle encompassing all monitors
        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = [int]::MinValue; $maxY = [int]::MinValue

        foreach ($m in $mons) {
            if ($m.Left -lt $minX) { $minX = $m.Left }
            if ($m.Top -lt $minY) { $minY = $m.Top }
            if ($m.Right -gt $maxX) { $maxX = $m.Right }
            if ($m.Bottom -gt $maxY) { $maxY = $m.Bottom }
        }

        $totalW = [Math]::Max(100, $maxX - $minX)
        $totalH = [Math]::Max(100, $maxY - $minY)

        $availW = $pnlCanvas.Width - 40
        $availH = $pnlCanvas.Height - 30
        # True Aspect Ratio Scale factor: identical scale for X and Y!
        $scale = [Math]::Min($availW / $totalW, $availH / $totalH)

        $drawOffsetX = 20 + [int](($availW - ($totalW * $scale)) / 2)
        $drawOffsetY = 15 + [int](($availH - ($totalH * $scale)) / 2)

        $curIdx = $cmbMonitorPick.SelectedIndex

        for ($i = 0; $i -lt $mons.Count; $i++) {
            $mon = $mons[$i]
            $rx = $drawOffsetX + [int](($mon.Left - $minX) * $scale)
            $ry = $drawOffsetY + [int](($mon.Top - $minY) * $scale)
            $rw = [Math]::Max(10, [int](($mon.Right - $mon.Left) * $scale))
            $rh = [Math]::Max(10, [int](($mon.Bottom - $mon.Top) * $scale))

            $rect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)

            # Determine image for this monitor
            $key = "$($i + 1)"
            $path = ""
            if ($cmbSizing.SelectedIndex -eq 5) {
                $path = $spanImageState
            } elseif ($wallState.Contains($key) -and $wallState[$key]) {
                $path = $wallState[$key]
            } elseif ($mon.CurrentWallpaper) {
                $path = $mon.CurrentWallpaper
            }

            # Adjustments for this monitor
            $adj = if ($adjState.Contains($key)) { $adjState[$key] } else { $null }
            $bgColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
            if ($adj -and $adj.BgColor) {
                try { $bgColor = [System.Drawing.ColorTranslator]::FromHtml($adj.BgColor) } catch {}
            }

            # Fill monitor background
            $bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
            $g.FillRectangle($bgBrush, $rect)
            $bgBrush.Dispose()

            $imgToDraw = $null
            if ($path -and (Test-Path -LiteralPath $path)) {
                try {
                    $rawImg = [System.Drawing.Image]::FromFile($path)
                    $imgToDraw = New-Object System.Drawing.Bitmap($rawImg)
                    $rawImg.Dispose()

                    # Apply live flip if set
                    if ($adj) {
                        if ($adj.FlipH -and $adj.FlipV) {
                            $imgToDraw.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipXY)
                        } elseif ($adj.FlipH) {
                            $imgToDraw.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
                        } elseif ($adj.FlipV) {
                            $imgToDraw.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY)
                        }
                    }
                } catch {}
            }

            if ($imgToDraw) {
                # Save graphics state and clip to this monitor rectangle
                $prevClip = $g.Clip
                $g.SetClip($rect)

                # Scaled pixel offsets (scaled proportionally to monitor preview)
                $monW = $mon.Right - $mon.Left
                $monH = $mon.Bottom - $mon.Top
                $pxScaleX = if ($monW -gt 0) { $rw / $monW } else { $scale }
                $pxScaleY = if ($monH -gt 0) { $rh / $monH } else { $scale }

                $offX = if ($adj) { [int]($adj.OffsetX * $pxScaleX) } else { 0 }
                $offY = if ($adj) { [int]($adj.OffsetY * $pxScaleY) } else { 0 }

                $sizing = $cmbSizing.SelectedItem.ToString()
                $iw = $imgToDraw.Width
                $ih = $imgToDraw.Height

                if ($sizing -like "*Fit Best*") {
                    # Fit: letterbox
                    $imgScale = [Math]::Min($rw / $iw, $rh / $ih)
                    $dw = [int]($iw * $imgScale)
                    $dh = [int]($ih * $imgScale)
                    $dx = $rx + [int](($rw - $dw) / 2) + $offX
                    $dy = $ry + [int](($rh - $dh) / 2) + $offY
                    $g.DrawImage($imgToDraw, $dx, $dy, $dw, $dh)
                } elseif ($sizing -like "*Stretch*") {
                    $g.DrawImage($imgToDraw, $rx + $offX, $ry + $offY, $rw, $rh)
                } elseif ($sizing -like "*Center*") {
                    $dw = [int]($iw * $scale)
                    $dh = [int]($ih * $scale)
                    $dx = $rx + [int](($rw - $dw) / 2) + $offX
                    $dy = $ry + [int](($rh - $dh) / 2) + $offY
                    $g.DrawImage($imgToDraw, $dx, $dy, $dw, $dh)
                } else {
                    # Fill: fit and clip
                    $imgScale = [Math]::Max($rw / $iw, $rh / $ih)
                    $dw = [int]($iw * $imgScale)
                    $dh = [int]($ih * $imgScale)
                    $dx = $rx + [int](($rw - $dw) / 2) + $offX
                    $dy = $ry + [int](($rh - $dh) / 2) + $offY
                    $g.DrawImage($imgToDraw, $dx, $dy, $dw, $dh)
                }

                $g.Clip = $prevClip
                $imgToDraw.Dispose()
            }

            # Border: Highlight currently selected monitor with bold red border
            $isSelected = ($i -eq $curIdx)
            $borderPen = if ($isSelected) {
                New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(239, 68, 68), 3)
            } else {
                New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(203, 213, 225), 2)
            }
            $g.DrawRectangle($borderPen, $rect)
            $borderPen.Dispose()

            # Monitor number badge in upper-left corner
            $badgeRect = New-Object System.Drawing.Rectangle($rx + 4, $ry + 4, 24, 22)
            $badgeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 0, 0, 0))
            $g.FillRectangle($badgeBrush, $badgeRect)
            $badgeBrush.Dispose()

            $badgeFont = New-Object System.Drawing.Font("Segoe UI", 9.0, [System.Drawing.FontStyle]::Bold)
            $textBrush = [System.Drawing.Brushes]::White
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString("$($i + 1)", $badgeFont, $textBrush, $badgeRect, $sf)

            # Resolution badge at bottom
            $resText = "$($mon.Width)x$($mon.Height)"
            $resFont = New-Object System.Drawing.Font("Segoe UI", 7.5)
            $resSize = $g.MeasureString($resText, $resFont)
            $resRect = New-Object System.Drawing.Rectangle($rx + $rw - [int]$resSize.Width - 6, $ry + $rh - [int]$resSize.Height - 4, [int]$resSize.Width + 4, [int]$resSize.Height + 2)
            $g.FillRectangle($badgeBrush, $resRect)
            $g.DrawString($resText, $resFont, $textBrush, $resRect, $sf)

            $badgeFont.Dispose()
            $resFont.Dispose()
            $sf.Dispose()
        }
    })

    # Allow clicking on a monitor box in the canvas to select it
    $pnlCanvas.add_MouseDown({
        param($sender, $e)
        if ($cmbSizing.SelectedIndex -eq 5) { return } # Span mode

        $minX = [int]::MaxValue; $minY = [int]::MaxValue
        $maxX = [int]::MinValue; $maxY = [int]::MinValue
        foreach ($m in $mons) {
            if ($m.Left -lt $minX) { $minX = $m.Left }
            if ($m.Top -lt $minY) { $minY = $m.Top }
            if ($m.Right -gt $maxX) { $maxX = $m.Right }
            if ($m.Bottom -gt $maxY) { $maxY = $m.Bottom }
        }
        $totalW = [Math]::Max(100, $maxX - $minX)
        $totalH = [Math]::Max(100, $maxY - $minY)
        $availW = $pnlCanvas.Width - 40
        $availH = $pnlCanvas.Height - 30
        $scale = [Math]::Min($availW / $totalW, $availH / $totalH)
        $drawOffsetX = 20 + [int](($availW - ($totalW * $scale)) / 2)
        $drawOffsetY = 15 + [int](($availH - ($totalH * $scale)) / 2)

        for ($i = 0; $i -lt $mons.Count; $i++) {
            $mon = $mons[$i]
            $rx = $drawOffsetX + [int](($mon.Left - $minX) * $scale)
            $ry = $drawOffsetY + [int](($mon.Top - $minY) * $scale)
            $rw = [Math]::Max(10, [int](($mon.Right - $mon.Left) * $scale))
            $rh = [Math]::Max(10, [int](($mon.Bottom - $mon.Top) * $scale))
            $rect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)

            if ($rect.Contains($e.Location)) {
                $cmbMonitorPick.SelectedIndex = $i
                break
            }
        }
    })

    # "Preview Now" Button to immediately test on live monitors
    $btnPreviewNow = New-Object System.Windows.Forms.Button
    $btnPreviewNow.Text = "Preview Now On Displays"
    $btnPreviewNow.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.0, [System.Drawing.FontStyle]::Bold)
    $btnPreviewNow.Location = New-Object System.Drawing.Point(20, 685)
    $btnPreviewNow.Size = New-Object System.Drawing.Size(185, 34)
    $btnPreviewNow.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
    $btnPreviewNow.ForeColor = [System.Drawing.Color]::White
    $btnPreviewNow.FlatStyle = "Flat"
    $dlgWall.Controls.Add($btnPreviewNow)

    $posKeyMap = @{
        0 = "Fill"
        1 = "Fit"
        2 = "Stretch"
        3 = "Center"
        4 = "Tile"
        5 = "Span"
    }

    $btnPreviewNow.add_Click({
        $posCode = $cmbSizing.SelectedIndex
        $activeLiveMons = [DesktopWallpaperNative]::GetActiveMonitors()
        if (-not $activeLiveMons -or $activeLiveMons.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Live preview is only possible when displays are currently active in Windows.", "Cannot Preview", "OK", "Information")
            return
        }

        if ($posCode -eq 5) {
            # Span
            $spanImg = $txtImgPath.Text.Trim()
            if ($spanImg -and (Test-Path -LiteralPath $spanImg)) {
                [DesktopWallpaperNative]::ApplyWallpaper($null, $spanImg, 5) | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show("Please choose a valid image file to test span mode.", "No Image", "OK", "Warning")
            }
        } else {
            $cacheDir = Join-Path $env:LOCALAPPDATA "DeskShift\WallpaperCache"
            for ($m = 0; $m -lt $activeLiveMons.Count; $m++) {
                $mon = $activeLiveMons[$m]
                $k = "$($m + 1)"
                $img = if ($wallState.Contains($k)) { $wallState[$k] } else { "" }
                if ($img -and (Test-Path -LiteralPath $img)) {
                    $adj = if ($adjState.Contains($k)) { $adjState[$k] } else { $null }
                    $targetW = [Math]::Max(100, $mon.Right - $mon.Left)
                    $targetH = [Math]::Max(100, $mon.Bottom - $mon.Top)

                    $hasTransformation = ($adj -and (
                        ($adj.OffsetX -and [int]$adj.OffsetX -ne 0) -or
                        ($adj.OffsetY -and [int]$adj.OffsetY -ne 0) -or
                        ($adj.FlipH -and [bool]$adj.FlipH) -or
                        ($adj.FlipV -and [bool]$adj.FlipV) -or
                        ($adj.BgColor -and $adj.BgColor -ne "#000000")
                    ))

                    if ($hasTransformation) {
                        $renderedOut = Join-Path $cacheDir "preview_mon${k}.png"
                        $appliedImg = New-TransformedWallpaper -SourcePath $img -TargetWidth $targetW -TargetHeight $targetH -SizingMode $posKeyMap[$posCode] -OffsetX ([int]$adj.OffsetX) -OffsetY ([int]$adj.OffsetY) -FlipH ([bool]$adj.FlipH) -FlipV ([bool]$adj.FlipV) -BgColorHex $adj.BgColor -OutputPath $renderedOut
                        if ($appliedImg) {
                            [DesktopWallpaperNative]::ApplyWallpaper($mon.Path, $appliedImg, 4) | Out-Null
                            continue
                        }
                    }

                    [DesktopWallpaperNative]::ApplyWallpaper($mon.Path, $img, $posCode) | Out-Null
                }
            }
        }
    })

    # Save and Cancel
    $btnSaveWall = New-Object System.Windows.Forms.Button
    $btnSaveWall.Text = "Save Wallpaper Settings"
    $btnSaveWall.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveWall.Location = New-Object System.Drawing.Point(585, 685)
    $btnSaveWall.Size = New-Object System.Drawing.Size(180, 34)
    $btnSaveWall.BackColor = [System.Drawing.Color]::FromArgb(225, 29, 72)
    $btnSaveWall.ForeColor = [System.Drawing.Color]::White
    $btnSaveWall.FlatStyle = "Flat"
    $dlgWall.Controls.Add($btnSaveWall)

    $btnCancelWall = New-Object System.Windows.Forms.Button
    $btnCancelWall.Text = "Cancel"
    $btnCancelWall.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancelWall.Location = New-Object System.Drawing.Point(785, 685)
    $btnCancelWall.Size = New-Object System.Drawing.Size(100, 34)
    $dlgWall.Controls.Add($btnCancelWall)
    $dlgWall.AcceptButton = $btnSaveWall
    $dlgWall.CancelButton = $btnCancelWall

    & $updateSelectedMonitorField

    if ($dlgWall.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $enabled = $chkEnableWall.Checked
        $posName = $posKeyMap[$cmbSizing.SelectedIndex]

        $cleanMonitors = [ordered]@{}
        foreach ($k in $wallState.Keys) {
            $cleanVal = $wallState[$k]
            if ($cleanVal -and $cleanVal.Trim()) {
                $cleanMonitors[$k] = $cleanVal.Trim()
            }
        }

        $cleanAdjustments = [ordered]@{}
        foreach ($k in $adjState.Keys) {
            $cleanAdjustments[$k] = $adjState[$k]
        }

        $wObj = [PSCustomObject]@{
            Enabled     = $enabled
            Position    = $posName
            Monitors    = $cleanMonitors
            Adjustments = $cleanAdjustments
            SpanImage   = $spanImageState
        }

        if ($profObj.PSObject.Properties["Wallpapers"]) {
            $profObj.Wallpapers = $wObj
        } else {
            $profObj | Add-Member -MemberType NoteProperty -Name "Wallpapers" -Value $wObj
        }

        Save-LiveConfig -cfg $liveCfg
        & $refreshMatrixGrid
        $statusMsg = if ($enabled) { "Enabled ($posName)" } else { "Disabled" }
        [System.Windows.Forms.MessageBox]::Show("Wallpaper settings saved for '$targetProfName': $statusMsg", "Settings Saved", "OK", "Information")
    }
})

# Delete Selected Profile Button Handler
$btnDeleteProfile.add_Click({
    if (-not $cmbProfiles.SelectedItem) { return }
    $selItem = $cmbProfiles.SelectedItem
    $selName = if ($selItem.Name) { $selItem.Name } else { $selItem.ToString() }

    if ($selName -in @("Desk (Dual 2K)", "Desk (Single Screen)")) {
        [System.Windows.Forms.MessageBox]::Show("System default profiles cannot be deleted.", "Protected Profile", "OK", "Warning")
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show("Delete profile '$selName' from DeskShift?", "Confirm Delete", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        $liveCfg = Get-LiveConfig
        $liveCfg.Profiles = @($liveCfg.Profiles | Where-Object { $_.Name -ne $selName })
        Save-LiveConfig -cfg $liveCfg

        $nativeJson = Join-Path $configDir "$selName.native.json"
        if (Test-Path -LiteralPath $nativeJson) { Remove-Item -LiteralPath $nativeJson -Force -ErrorAction SilentlyContinue }

        & $refreshMatrixGrid
        if ($refreshWebProfilesGrid) { & $refreshWebProfilesGrid }
        if ($updateWebTabDisplay) { & $updateWebTabDisplay }
        [System.Windows.Forms.MessageBox]::Show("Profile '$selName' deleted.", "Deleted", "OK", "Information")
    }
})

# Test Smart Plug Helper
function Test-SmartPlug ($turnOn) {
    if ($plugListView.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a smart plug from the list first.", "Select Plug", "OK", "Information")
        return
    }
    $plugKey = $plugListView.SelectedItems[0].Tag.Key
    $scriptDir = Split-Path $ConfigFile
    $runner = Join-Path $scriptDir "scripts\tapo-runner.js"
    $action = if ($turnOn) { "on" } else { "off" }
    
    # Save current credentials to json first
    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.TapoCredentials) {
        $liveCfg | Add-Member -MemberType NoteProperty -Name "TapoCredentials" -Value (New-Object PSObject)
    }
    $liveCfg.TapoCredentials.Email = $txtEmail.Text.Trim()
    $liveCfg.TapoCredentials.Password = $txtPass.Text.Trim()
    Save-LiveConfig -cfg $liveCfg

    $p = Start-Process -FilePath "node.exe" -ArgumentList "`"$runner`" set $plugKey $action" -WorkingDirectory $scriptDir -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Smart plug command sent successfully!", "Success", "OK", "Information")
    } else {
        [System.Windows.Forms.MessageBox]::Show("Failed to toggle plug. Verify IP and credentials if using Tapo.", "Error", "OK", "Error")
    }
}

$btnTestPlugOn.add_Click({ Test-SmartPlug $true })
$btnTestPlugOff.add_Click({ Test-SmartPlug $false })

# Function to populate Add Device ComboBox
$refreshAddCombo = {
    $addCombo.Items.Clear()
    $connected = Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -like "USB\*" -and $_.Class -in @("HIDClass", "MEDIA", "Bluetooth", "USB", "Image", "Ports") -and $_.FriendlyName -notmatch "Root Hub|Composite Device|Input Device"
    } | Sort-Object FriendlyName

    foreach ($d in $connected) {
        $display = "$($d.FriendlyName) [$($d.Class)]"
        $addCombo.Items.Add([PSCustomObject]@{ Display = $display; Name = $d.FriendlyName; InstanceId = $d.InstanceId }) | Out-Null
    }
    $addCombo.DisplayMember = "Display"
    if ($addCombo.Items.Count -gt 0) { $addCombo.SelectedIndex = 0 }
}

$addCombo.add_SelectedIndexChanged({
    if ($addCombo.SelectedItem) {
        $addNameBox.Text = $addCombo.SelectedItem.Name
        $addKeyBox.Text = ($addCombo.SelectedItem.Name -replace '[^a-zA-Z0-9]', '')
    }
})

$addNameBox.add_TextChanged({
    # If key box is empty or matches previous auto-clean, update it automatically
    if (-not $addKeyBox.Text -or $addKeyBox.Tag -eq "auto") {
        $addKeyBox.Text = ($addNameBox.Text -replace '[^a-zA-Z0-9]', '')
        $addKeyBox.Tag = "auto"
    }
})

$addKeyBox.add_KeyPress({
    $addKeyBox.Tag = "manual"
})

# Add USB Device Button Handler
$addBtn.add_Click({
    if (-not $addCombo.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Please select a connected device from the dropdown first.", "No Device Selected", "OK", "Warning")
        return
    }

    $selItem = $addCombo.SelectedItem
    $friendlyName = $addNameBox.Text.Trim()
    if (-not $friendlyName) { $friendlyName = $selItem.Name }
    $instanceId = $selItem.InstanceId

    # Use custom key if user typed one, otherwise sanitize name
    $customKey = $addKeyBox.Text.Trim()
    $cleanKey = ($customKey -replace '[^a-zA-Z0-9_]', '')
    if (-not $cleanKey) {
        $cleanKey = ($friendlyName -replace '[^a-zA-Z0-9_]', '')
    }
    if (-not $cleanKey) { $cleanKey = "UsbDevice" + (Get-Random -Minimum 100 -Maximum 999) }

    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.DeviceDefinitions) {
        $liveCfg | Add-Member -MemberType NoteProperty -Name "DeviceDefinitions" -Value (New-Object PSObject)
    }

    # Ensure key uniqueness if duplicate name
    $baseKey = $cleanKey
    $counter = 1
    while ($liveCfg.DeviceDefinitions.PSObject.Properties[$cleanKey]) {
        $cleanKey = "${baseKey}_${counter}"
        $counter++
    }

    $newDev = [PSCustomObject]@{
        Name = $friendlyName
        InstanceId = $instanceId
    }
    $liveCfg.DeviceDefinitions | Add-Member -MemberType NoteProperty -Name $cleanKey -Value $newDev

    Save-LiveConfig -cfg $liveCfg
    & $refreshDeviceList
    & $refreshMatrixGrid
    [System.Windows.Forms.MessageBox]::Show("USB device '$friendlyName' added with Config Key '$cleanKey'!", "Device Added", "OK", "Information")
})

# Rename USB Device Friendly Name Handler
$doRenameDev = {
    if ($deviceListView.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select a managed device from the list above first.", "No Selection", "OK", "Information")
        return
    }

    $selDev = $deviceListView.SelectedItems[0].Tag
    $devKey = $selDev.Key
    $currentName = $selDev.Name

    $renameForm = New-Object System.Windows.Forms.Form
    $renameForm.Text = "Rename USB Device"
    $renameForm.Size = New-Object System.Drawing.Size(460, 200)
    $renameForm.StartPosition = "CenterParent"
    $renameForm.FormBorderStyle = "FixedDialog"
    $renameForm.MaximizeBox = $false
    $renameForm.MinimizeBox = $false
    $renameForm.Font = New-Object System.Drawing.Font("Segoe UI", 9.0)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Change the friendly name for this device (Config Key: $devKey):"
    $lblInfo.Location = New-Object System.Drawing.Point(20, 20)
    $lblInfo.Size = New-Object System.Drawing.Size(410, 25)
    $renameForm.Controls.Add($lblInfo)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(20, 55)
    $txtName.Size = New-Object System.Drawing.Size(400, 27)
    $txtName.Text = $currentName
    $txtName.SelectAll()
    $renameForm.Controls.Add($txtName)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Save Name"
    $btnOk.Location = New-Object System.Drawing.Point(210, 110)
    $btnOk.Size = New-Object System.Drawing.Size(100, 32)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = "Flat"
    $renameForm.Controls.Add($btnOk)
    $renameForm.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(320, 110)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $renameForm.Controls.Add($btnCancel)
    $renameForm.CancelButton = $btnCancel

    if ($renameForm.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $newName = $txtName.Text.Trim()
        if (-not $newName) {
            [System.Windows.Forms.MessageBox]::Show("Friendly name cannot be empty.", "Invalid Name", "OK", "Warning")
            return
        }

        $liveCfg = Get-LiveConfig
        if ($liveCfg.DeviceDefinitions -and $liveCfg.DeviceDefinitions.PSObject.Properties[$devKey]) {
            $liveCfg.DeviceDefinitions.$devKey.Name = $newName
            Save-LiveConfig -cfg $liveCfg
            & $refreshDeviceListFast
            & $refreshMatrixGrid
            [System.Windows.Forms.MessageBox]::Show("Device renamed to '$newName'.", "Renamed", "OK", "Information")
        }
    }
}

$renameDevBtn.add_Click($doRenameDev)
$deviceListView.add_DoubleClick($doRenameDev)

# Remove USB Device from Management Handler
$removeDevBtn.add_Click({
    if ($deviceListView.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select a managed device from the list above.", "No Selection", "OK", "Information")
        return
    }

    $selDev = $deviceListView.SelectedItems[0].Tag
    $devKey = $selDev.Key
    $devName = $selDev.Name

    $confirm = [System.Windows.Forms.MessageBox]::Show("Remove '$devName' ($devKey) from USB management?", "Confirm Removal", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        $liveCfg = Get-LiveConfig
        if ($liveCfg.DeviceDefinitions -and $liveCfg.DeviceDefinitions.PSObject.Properties[$devKey]) {
            $liveCfg.DeviceDefinitions.PSObject.Properties.Remove($devKey)

            # Also clean up references in profiles
            foreach ($prof in $liveCfg.Profiles) {
                if ($prof.Devices -and $prof.Devices.PSObject.Properties[$devKey]) {
                    $prof.Devices.PSObject.Properties.Remove($devKey)
                }
            }

            Save-LiveConfig -cfg $liveCfg
            & $refreshDeviceList
            & $refreshMatrixGrid
            [System.Windows.Forms.MessageBox]::Show("Device '$devName' removed from management.", "Removed", "OK", "Information")
        }
    }
})

# Test ON / OFF USB Buttons
$testOnBtn.add_Click({
    if ($deviceListView.SelectedItems.Count -eq 0) { return }
    $sel = $deviceListView.SelectedItems[0].Tag
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & pnputil.exe /enable-device "$($sel.InstanceId)" | Out-Null
    } else {
        $p = Start-Process pnputil.exe -ArgumentList "/enable-device `"$($sel.InstanceId)`"" -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    }
    Start-Sleep -Milliseconds 500
    & $refreshDeviceList
})

$testOffBtn.add_Click({
    if ($deviceListView.SelectedItems.Count -eq 0) { return }
    $sel = $deviceListView.SelectedItems[0].Tag
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & pnputil.exe /disable-device "$($sel.InstanceId)" | Out-Null
    } else {
        $p = Start-Process pnputil.exe -ArgumentList "/disable-device `"$($sel.InstanceId)`"" -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    }
    Start-Sleep -Milliseconds 500
    & $refreshDeviceList
})

# Save All Settings
$saveBtn.add_Click({
    $liveCfg = Get-LiveConfig

    if (-not $liveCfg.TapoCredentials) { $liveCfg | Add-Member -MemberType NoteProperty -Name "TapoCredentials" -Value (New-Object PSObject) }
    $liveCfg.TapoCredentials.Email = $txtEmail.Text.Trim()
    $liveCfg.TapoCredentials.Password = $txtPass.Text.Trim()

    # Read the transposed matrix:
    # Each row represents a device/plug: row.Tag.Category ("PLUG" or "USB"), row.Tag.Key
    # Each column (after column 0) represents a Profile
    foreach ($prof in $liveCfg.Profiles) {
        if ($prof.Separator -or $prof.Hidden) { continue }
        $colName = "PROF_" + $prof.Name
        if (-not $matrixGrid.Columns.Contains($colName)) { continue }

        if (-not $prof.Plugs) { $prof | Add-Member -MemberType NoteProperty -Name "Plugs" -Value (New-Object PSObject) }
        if (-not $prof.Devices) { $prof | Add-Member -MemberType NoteProperty -Name "Devices" -Value (New-Object PSObject) }

        foreach ($row in $matrixGrid.Rows) {
            $cat = $row.Tag.Category
            $itemKey = $row.Tag.Key
            $val = [bool]$row.Cells[$colName].Value

            if ($cat -eq "PLUG") {
                if ($prof.Plugs.PSObject.Properties[$itemKey]) {
                    $prof.Plugs.$itemKey = $val
                } else {
                    $prof.Plugs | Add-Member -MemberType NoteProperty -Name $itemKey -Value $val
                }
            } elseif ($cat -eq "USB") {
                if ($prof.Devices.PSObject.Properties[$itemKey]) {
                    $prof.Devices.$itemKey = $val
                } else {
                    $prof.Devices | Add-Member -MemberType NoteProperty -Name $itemKey -Value $val
                }
            }
        }
    }

    # Save Web Remote Settings
    if (-not $liveCfg.WebRemote) {
        $liveCfg | Add-Member -MemberType NoteProperty -Name "WebRemote" -Value (New-Object PSObject)
    }
    $liveCfg.WebRemote.Enabled = [bool]$chkEnableWebRemote.Checked
    $liveCfg.WebRemote.Domain = $txtWebDomain.Text.Trim()
    $liveCfg.WebRemote.Port = [int]$numWebPort.Value

    # Save Custom Web Remote Profile Button Configurations (Show on Phone, Icon, Color)
    foreach ($wRow in $webGrid.Rows) {
        $pName = $wRow.Tag
        if (-not $pName) { continue }
        $targetProf = $liveCfg.Profiles | Where-Object { $_.Name -eq $pName } | Select-Object -First 1
        if ($targetProf) {
            $wVis = [bool]$wRow.Cells["WebVisible"].Value
            $wIco = if ($wRow.Cells["WebIcon"].Value) { $wRow.Cells["WebIcon"].Value.ToString().Trim() } else { "🖥️" }
            $wCol = if ($wRow.Cells["WebColor"].Value) { $wRow.Cells["WebColor"].Value.ToString().Trim() } else { "#3b82f6" }

            if ($targetProf.PSObject.Properties["WebVisible"]) { $targetProf.WebVisible = $wVis }
            else { $targetProf | Add-Member -MemberType NoteProperty -Name "WebVisible" -Value $wVis }

            if ($targetProf.PSObject.Properties["WebIcon"]) { $targetProf.WebIcon = $wIco }
            else { $targetProf | Add-Member -MemberType NoteProperty -Name "WebIcon" -Value $wIco }

            if ($targetProf.PSObject.Properties["WebColor"]) { $targetProf.WebColor = $wCol }
            else { $targetProf | Add-Member -MemberType NoteProperty -Name "WebColor" -Value $wCol }
        }
    }

    # Save Advanced Hardware Settings
    if (-not $liveCfg.AdvancedSettings) {
        $liveCfg | Add-Member -MemberType NoteProperty -Name "AdvancedSettings" -Value (New-Object PSObject)
    }
    $liveCfg.AdvancedSettings.UsbToggleDelayMs = [int]$numUsbDelay.Value
    $liveCfg.AdvancedSettings.PreSwitchPlugDelayMs = [int]$numPlugDelay.Value
    $liveCfg.AdvancedSettings.DisplaySwitchTimeoutSeconds = [int]$numTimeout.Value
    $liveCfg.AdvancedSettings.PurgePhantomUsbDevices = [bool]$chkPurgePhantom.Checked
    $liveCfg.AdvancedSettings.PrioritizeHubOrder = [bool]$chkPrioritizeHub.Checked

    # Save Auto-Start with Windows (HKCU Run)
    $scriptDir = Split-Path $ConfigFile
    $lnkLauncher = Join-Path $scriptDir "DeskShift.lnk"
    $vbsLauncher = Join-Path $scriptDir "DeskShift.vbs"
    $startupTarget = if (Test-Path -LiteralPath $lnkLauncher) { "`"$lnkLauncher`"" } else { "wscript.exe `"$vbsLauncher`"" }

    if ($chkStartOnBootMain.Checked) {
        Set-ItemProperty -Path $regRunPath -Name $regRunName -Value $startupTarget -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -Path $regRunPath -Name $regRunName -ErrorAction SilentlyContinue
    }

    # Manage Web Remote background process state
    $appRoot = Split-Path (Split-Path $ConfigFile)
    $webRemoteVbs = Join-Path $appRoot "web-remote\Run-Silent.vbs"
    if ($chkEnableWebRemote.Checked) {
        $nodeListening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in @([int]$numWebPort.Value, 443) }
        if (-not $nodeListening) {
            if (Test-Path -LiteralPath $webRemoteVbs) {
                Start-Process "wscript.exe" -ArgumentList "`"$webRemoteVbs`"" -WorkingDirectory (Split-Path $webRemoteVbs) -WindowStyle Hidden
            }
        }
    } else {
        # If disabled by user, stop any running background web-remote instance
        Get-Process node -ErrorAction SilentlyContinue | Where-Object {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
            $cmd -like "*DeskShift*server.js*"
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Save-LiveConfig -cfg $liveCfg
    [System.Windows.Forms.MessageBox]::Show("Settings, Profile Matrix, and Hardware Config saved successfully!", "Saved", "OK", "Information")
})

$closeBtn.add_Click({ $form.Close() })

# Function to populate Advanced Settings
$refreshAdvancedSettings = {
    $liveCfg = Get-LiveConfig
    if ($liveCfg.AdvancedSettings) {
        if ($null -ne $liveCfg.AdvancedSettings.UsbToggleDelayMs) {
            $numUsbDelay.Value = [Math]::Min([Math]::Max([decimal]$liveCfg.AdvancedSettings.UsbToggleDelayMs, $numUsbDelay.Minimum), $numUsbDelay.Maximum)
        }
        if ($null -ne $liveCfg.AdvancedSettings.PreSwitchPlugDelayMs) {
            $numPlugDelay.Value = [Math]::Min([Math]::Max([decimal]$liveCfg.AdvancedSettings.PreSwitchPlugDelayMs, $numPlugDelay.Minimum), $numPlugDelay.Maximum)
        }
        $timeoutVal = if ($null -ne $liveCfg.AdvancedSettings.DisplaySwitchTimeoutSeconds) {
            $liveCfg.AdvancedSettings.DisplaySwitchTimeoutSeconds
        } else { $null }

        if ($null -ne $timeoutVal) {
            $numTimeout.Value = [Math]::Min([Math]::Max([decimal]$timeoutVal, $numTimeout.Minimum), $numTimeout.Maximum)
        }
        if ($null -ne $liveCfg.AdvancedSettings.PurgePhantomUsbDevices) {
            $chkPurgePhantom.Checked = [bool]$liveCfg.AdvancedSettings.PurgePhantomUsbDevices
        }
        if ($null -ne $liveCfg.AdvancedSettings.PrioritizeHubOrder) {
            $chkPrioritizeHub.Checked = [bool]$liveCfg.AdvancedSettings.PrioritizeHubOrder
        }
    }
}

# Function to populate Device List immediately with cached config (no slow PnP calls)
$refreshDeviceListFast = {
    $deviceListView.Items.Clear()
    $liveCfg = Get-LiveConfig
    if (-not $liveCfg.DeviceDefinitions) { return }

    foreach ($prop in $liveCfg.DeviceDefinitions.PSObject.Properties) {
        $dev = $prop.Value
        $item = New-Object System.Windows.Forms.ListViewItem($dev.Name)
        $item.SubItems.Add($prop.Name) | Out-Null
        $item.SubItems.Add("Checking...") | Out-Null
        $item.SubItems.Add($dev.InstanceId) | Out-Null
        $item.Tag = [PSCustomObject]@{ Key = $prop.Name; InstanceId = $dev.InstanceId; Name = $dev.Name; Status = "Checking..." }
        $deviceListView.Items.Add($item) | Out-Null
    }
}

# Initial fast population for instant UI display
& $refreshDeviceListFast
& $refreshMatrixGrid
& $refreshPlugsInputs
& $refreshAdvancedSettings
& $refreshWebProfilesGrid
& $refreshCertInfo

# Fast post-render timer to update live statuses without blocking window appearance
$pnpStatusTimer = New-Object System.Windows.Forms.Timer
$pnpStatusTimer.Interval = 50
$pnpStatusTimer.add_Tick({
    $pnpStatusTimer.Stop()
    
    # Bulk scan present devices in ~600ms
    $pnpMap = @{}
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $pnpMap[$_.InstanceId] = $_.Status }

    $liveCfg = Get-LiveConfig
    if ($liveCfg.DeviceDefinitions) {
        $deviceListView.BeginUpdate()
        $deviceListView.Items.Clear()
        foreach ($prop in $liveCfg.DeviceDefinitions.PSObject.Properties) {
            $dev = $prop.Value
            $id = $dev.InstanceId
            $status = if ($pnpMap.ContainsKey($id)) {
                if ($pnpMap[$id] -eq "OK") { "ON (Active)" } else { "OFF (Disabled)" }
            } else {
                "Disconnected"
            }

            $item = New-Object System.Windows.Forms.ListViewItem($dev.Name)
            $item.SubItems.Add($prop.Name) | Out-Null
            $item.SubItems.Add($status) | Out-Null
            $item.SubItems.Add($id) | Out-Null
            $item.Tag = [PSCustomObject]@{ Key = $prop.Name; InstanceId = $id; Name = $dev.Name; Status = $status }
            $deviceListView.Items.Add($item) | Out-Null
        }
        $deviceListView.EndUpdate()
    }
})

$form.add_Shown({
    $pnpStatusTimer.Start()

    $tabWeb.add_Enter({
        if ($refreshWebProfilesGrid) { & $refreshWebProfilesGrid }
        if ($updateWebTabDisplay) { & $updateWebTabDisplay }
    })

    $tabDevices.add_Enter({
        if ($addCombo.Items.Count -eq 0) {
            & $refreshAddCombo
        }
    })
})

[System.Windows.Forms.Application]::Run($form)
