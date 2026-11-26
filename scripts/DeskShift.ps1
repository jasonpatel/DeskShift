[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$ProfileName,

    [Parameter()]
    [string]$ConfigFile,

    [Parameter()]
    [switch]$Tray,

    [Parameter()]
    [switch]$List,

    [Parameter()]
    [string]$Capture,

    [Parameter()]
    [switch]$Single,

    [Parameter()]
    [switch]$Toggle
)

# Resolve app root directory relative to this script (scripts\ -> ..)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$appRoot = Split-Path -Parent $scriptDir

if (-not $ConfigFile) {
    $ConfigFile = Join-Path (Join-Path $appRoot "config") "profiles.json"
}

# Force UTF-8 encoding across Windows console & file I/O
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Helper to read fresh configuration dynamically
function Get-CurrentConfig {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Error "Configuration file not found: $ConfigFile"
        return $null
    }
    $rawJson = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
    return ($rawJson | ConvertFrom-Json)
}

$initialConfig = Get-CurrentConfig
if (-not $initialConfig) { exit 1 }

$profilesDir = if ($initialConfig.ProfilesDir) { $initialConfig.ProfilesDir } else { $appRoot }
$configDir = Join-Path $profilesDir "config"
$iconsDir = Join-Path $profilesDir "icons"
$nativeEngine = Join-Path $profilesDir "bin\NativeEngine.exe"

# Initialize native Windows Core Audio Policy Client for instant, silent audio endpoint switching
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

[ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
public class PolicyConfigClient {}

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
                try {
                    string styleVal = "10";
                    string tileVal = "0";
                    switch (position) {
                        case 0: styleVal = "0"; tileVal = "0"; break; // Center
                        case 1: styleVal = "0"; tileVal = "1"; break; // Tile
                        case 2: styleVal = "2"; tileVal = "0"; break; // Stretch
                        case 3: styleVal = "6"; tileVal = "0"; break; // Fit
                        case 4: styleVal = "10"; tileVal = "0"; break; // Fill
                        case 5: styleVal = "22"; tileVal = "0"; break; // Span
                    }
                    using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop", true)) {
                        if (key != null) {
                            key.SetValue("WallpaperStyle", styleVal);
                            key.SetValue("TileWallpaper", tileVal);
                        }
                    }
                } catch {}
            }
            return dw.SetWallpaper(string.IsNullOrEmpty(monitorId) ? null : monitorId, wallpaperPath ?? "");
        } catch {
            return -1;
        }
    }
}
"@ -ErrorAction SilentlyContinue

# Function to capture active DPI scaling percentages from connected displays
function Get-CurrentDisplayScales {
    param([string]$AppRoot)
    $setDpiExe = Join-Path $AppRoot "bin\SetDpi.exe"
    $scales = @{}
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

# Function to apply saved DPI scaling percentages to connected displays
function Sync-ProfileDisplayScales {
    param($ProfileItem, [string]$AppRoot)
    if (-not $ProfileItem.DisplayScales) { return }
    $setDpiExe = Join-Path $AppRoot "bin\SetDpi.exe"
    if (-not (Test-Path -LiteralPath $setDpiExe)) { return }

    foreach ($prop in $ProfileItem.DisplayScales.PSObject.Properties) {
        $dispIdx = $prop.Name
        $scalePct = [int]$prop.Value
        if ($scalePct -gt 0) {
            Write-Host "Applying Windows DPI scale: Display $dispIdx -> $scalePct%" -ForegroundColor Cyan
            & $setDpiExe $scalePct $dispIdx | Out-Null
        }
    }
}

# Function to switch Windows Default Audio Endpoint to match profile
function Sync-ProfileAudio {
    param($ProfileItem)
    if (-not $ProfileItem.AudioDevice) { return }
    $targetAudio = $ProfileItem.AudioDevice.Trim()
    if (-not $targetAudio) { return }

    try {
        $renderKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render" -ErrorAction SilentlyContinue
        $matchedId = $null
        $matchedName = ""
        foreach ($k in $renderKeys) {
            $state = (Get-ItemProperty $k.PSPath).DeviceState
            if ($state -eq 1) { # Active endpoint
                $props = Get-ItemProperty (Join-Path $k.PSPath "Properties") -ErrorAction SilentlyContinue
                $devName = $props."{a45c254e-df1c-4efd-8020-67d146a850e0},2"
                $adapter = $props."{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
                $full = "$devName ($adapter)"

                if ($k.PSChildName -eq $targetAudio -or $devName -eq $targetAudio -or $full -eq $targetAudio -or $devName -like "*$targetAudio*" -or $full -like "*$targetAudio*") {
                    $matchedId = $k.PSChildName
                    $matchedName = $full
                    break
                }
            }
        }

        if ($matchedId) {
            $epString = "{0.0.0.00000000}.$matchedId"
            [AudioController]::SetDefault($epString) | Out-Null
            Write-Host "Audio endpoint switched to: $matchedName" -ForegroundColor Cyan
        } else {
            Write-Warning "Target audio device '$targetAudio' is not currently active or connected."
        }
    } catch {
        Write-Warning "Failed to switch audio endpoint: $_"
    }
}

# Function to launch an application or script associated with the profile
function Sync-ProfileLaunchApp {
    param($ProfileItem)
    if (-not $ProfileItem.LaunchApp -or -not $ProfileItem.LaunchApp.Trim()) { return }
    $appTarget = $ProfileItem.LaunchApp.Trim()
    $appArgs = if ($ProfileItem.LaunchAppArgs) { $ProfileItem.LaunchAppArgs.Trim() } else { "" }

    Write-Host "Triggering post-switch application launch: $appTarget $appArgs" -ForegroundColor Cyan
    try {
        if ($appArgs) {
            Start-Process -FilePath $appTarget -ArgumentList $appArgs
        } else {
            Start-Process -FilePath $appTarget
        }
    } catch {
        Write-Warning "Could not launch application '$appTarget': $_"
    }
}

# Helper to generate custom transformed wallpaper file (with offset, flip, bg color)
function New-TransformedWallpaper {
    param(
        [string]$SourcePath,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [string]$SizingMode,
        [int]$OffsetX = 0,
        [int]$OffsetY = 0,
        [double]$ScalePercent = 100.0,
        [bool]$FlipH = $false,
        [bool]$FlipV = $false,
        [string]$BgColorHex = "#000000",
        [string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }

    Add-Type -AssemblyName System.Drawing
    try {
        $srcImg = [System.Drawing.Image]::FromFile($SourcePath)
        $bmp = New-Object System.Drawing.Bitmap($srcImg)
        $srcImg.Dispose()

        if ($FlipH -and $FlipV) {
            $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipXY)
        } elseif ($FlipH) {
            $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
        } elseif ($FlipV) {
            $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY)
        }

        $destBmp = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($destBmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        $bgColor = try { [System.Drawing.ColorTranslator]::FromHtml($BgColorHex) } catch { [System.Drawing.Color]::Black }
        $brush = New-Object System.Drawing.SolidBrush($bgColor)
        $g.FillRectangle($brush, 0, 0, $TargetWidth, $TargetHeight)
        $brush.Dispose()

        $srcW = $bmp.Width
        $srcH = $bmp.Height
        $scaleMul = if ($ScalePercent -gt 0) { [Math]::Max(0.01, $ScalePercent / 100.0) } else { 1.0 }

        switch ($SizingMode) {
            "Stretch" {
                $dw = [int]($TargetWidth * $scaleMul)
                $dh = [int]($TargetHeight * $scaleMul)
                $x = [int](($TargetWidth - $dw) / 2) + $OffsetX
                $y = [int](($TargetHeight - $dh) / 2) + $OffsetY
                $destRect = New-Object System.Drawing.Rectangle($x, $y, $dw, $dh)
                $g.DrawImage($bmp, $destRect)
            }
            "Center" {
                $dw = [int]($srcW * $scaleMul)
                $dh = [int]($srcH * $scaleMul)
                $x = [int](($TargetWidth - $dw) / 2) + $OffsetX
                $y = [int](($TargetHeight - $dh) / 2) + $OffsetY
                $destRect = New-Object System.Drawing.Rectangle($x, $y, $dw, $dh)
                $g.DrawImage($bmp, $destRect)
            }
            "Tile" {
                $tb = New-Object System.Drawing.TextureBrush($bmp)
                if ($scaleMul -ne 1.0) { $tb.ScaleTransform($scaleMul, $scaleMul) }
                $tb.TranslateTransform($OffsetX, $OffsetY)
                $g.FillRectangle($tb, 0, 0, $TargetWidth, $TargetHeight)
                $tb.Dispose()
            }
            "Fit" {
                $baseScale = [Math]::Min($TargetWidth / $srcW, $TargetHeight / $srcH)
                $drawW = [int]($srcW * $baseScale * $scaleMul)
                $drawH = [int]($srcH * $baseScale * $scaleMul)
                $x = [int](($TargetWidth - $drawW) / 2) + $OffsetX
                $y = [int](($TargetHeight - $drawH) / 2) + $OffsetY
                $destRect = New-Object System.Drawing.Rectangle($x, $y, $drawW, $drawH)
                $g.DrawImage($bmp, $destRect)
            }
            default { # "Fill"
                $baseScale = [Math]::Max($TargetWidth / $srcW, $TargetHeight / $srcH)
                $drawW = [int]($srcW * $baseScale * $scaleMul)
                $drawH = [int]($srcH * $baseScale * $scaleMul)
                $x = [int](($TargetWidth - $drawW) / 2) + $OffsetX
                $y = [int](($TargetHeight - $drawH) / 2) + $OffsetY
                $destRect = New-Object System.Drawing.Rectangle($x, $y, $drawW, $drawH)
                $g.DrawImage($bmp, $destRect)
            }
        }

        $g.Dispose()
        $bmp.Dispose()

        $parentDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }

        $destBmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $destBmp.Dispose()
        return $OutputPath
    } catch {
        Write-Warning "Failed to render transformed wallpaper: $_"
        return $null
    }
}

# Function to apply per-profile desktop wallpapers with multi-monitor positioning
function Sync-ProfileWallpapers {
    param($ProfileItem)
    if (-not $ProfileItem.Wallpapers) { return }
    $wCfg = $ProfileItem.Wallpapers
    if (-not $wCfg.Enabled) { return }

    $posMap = @{
        "Center" = 0
        "Tile" = 1
        "Stretch" = 2
        "Fit" = 3
        "Fill" = 4
        "Span" = 5
    }
    $posCode = 4 # Default to Fill
    if ($wCfg.Position -and $posMap.ContainsKey($wCfg.Position)) {
        $posCode = $posMap[$wCfg.Position]
    }

    Write-Host "Applying wallpapers for profile: $($ProfileItem.Name) (Position: $($wCfg.Position))" -ForegroundColor Cyan
    try {
        $activeMons = [DesktopWallpaperNative]::GetActiveMonitors()
        if (-not $activeMons -or $activeMons.Count -eq 0) { return }

        # Mode A: Span across all monitors
        if ($wCfg.Position -eq "Span" -and $wCfg.SpanImage -and (Test-Path -LiteralPath $wCfg.SpanImage)) {
            $hasBezelComp = ($wCfg.BezelGap -and [int]$wCfg.BezelGap -gt 0) -or ($wCfg.CustomEdgeGaps -and [bool]$wCfg.CustomEdgeGaps)
            if ($hasBezelComp -and $activeMons.Count -gt 1) {
                # Spliced span with bezel gap compensation per monitor
                $totalGap = 0
                $cumGaps = @()
                for ($e = 0; $e -lt ($activeMons.Count - 1); $e++) {
                    $eName = "Edge $($e + 1) (M$($e + 1) - M$($e + 2))"
                    $eGap = if ($wCfg.CustomEdgeGaps -and $wCfg.EdgeGaps -and $wCfg.EdgeGaps.PSObject.Properties[$eName]) {
                        [int]$wCfg.EdgeGaps.$eName
                    } elseif ($wCfg.BezelGap) {
                        [int]$wCfg.BezelGap
                    } else { 0 }
                    $cumGaps += $totalGap
                    $totalGap += $eGap
                }
                $cumGaps += $totalGap

                $minX = ($activeMons | Measure-Object -Property Left -Minimum).Minimum
                $maxX = ($activeMons | Measure-Object -Property Right -Maximum).Maximum
                $minY = ($activeMons | Measure-Object -Property Top -Minimum).Minimum
                $maxY = ($activeMons | Measure-Object -Property Bottom -Maximum).Maximum
                $vTotalW = ($maxX - $minX) + $totalGap
                $vTotalH = [Math]::Max(100, $maxY - $minY)

                $cacheDir = Join-Path $env:LOCALAPPDATA "DeskShift\WallpaperCache"
                if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

                for ($m = 0; $m -lt $activeMons.Count; $m++) {
                    $mon = $activeMons[$m]
                    $tW = $mon.Right - $mon.Left
                    $tH = $mon.Bottom - $mon.Top
                    $monVirtX = ($mon.Left - $minX) + $cumGaps[$m]
                    $monVirtY = ($mon.Top - $minY)
                    $cleanProf = ($ProfileItem.Name -replace '[^a-zA-Z0-9_\-]', '_')
                    $renderedOut = Join-Path $cacheDir "${cleanProf}_span_mon$($m+1).png"
                    
                    # Generate sliced span wallpaper
                    $srcImg = [System.Drawing.Image]::FromFile($wCfg.SpanImage)
                    $sScale = [Math]::Max($vTotalW / $srcImg.Width, $vTotalH / $srcImg.Height)
                    $scaledW = [int]($srcImg.Width * $sScale)
                    $scaledH = [int]($srcImg.Height * $sScale)
                    $fullBmp = New-Object System.Drawing.Bitmap($vTotalW, $vTotalH)
                    $fg = [System.Drawing.Graphics]::FromImage($fullBmp)
                    $fg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $fg.DrawImage($srcImg, [int](($vTotalW - $scaledW) / 2), [int](($vTotalH - $scaledH) / 2), $scaledW, $scaledH)
                    $fg.Dispose()
                    $srcImg.Dispose()

                    $sliceBmp = New-Object System.Drawing.Bitmap($tW, $tH)
                    $sg = [System.Drawing.Graphics]::FromImage($sliceBmp)
                    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $sg.DrawImage($fullBmp, (New-Object System.Drawing.Rectangle(0, 0, $tW, $tH)), (New-Object System.Drawing.Rectangle($monVirtX, $monVirtY, $tW, $tH)), [System.Drawing.GraphicsUnit]::Pixel)
                    $sg.Dispose()
                    $fullBmp.Dispose()
                    $sliceBmp.Save($renderedOut, [System.Drawing.Imaging.ImageFormat]::Png)
                    $sliceBmp.Dispose()

                    [DesktopWallpaperNative]::ApplyWallpaper($mon.Path, $renderedOut, 4) | Out-Null
                }
                return
            } else {
                [DesktopWallpaperNative]::ApplyWallpaper($null, $wCfg.SpanImage, 5) | Out-Null
                return
            }
        }

        # Cache folder for transformed profile wallpapers
        $cacheDir = Join-Path $env:LOCALAPPDATA "DeskShift\WallpaperCache"

        # Mode B: Per-monitor images
        if ($wCfg.Monitors) {
            foreach ($prop in $wCfg.Monitors.PSObject.Properties) {
                $monIdxStr = $prop.Name
                $imgFile = $prop.Value
                if ($imgFile -and (Test-Path -LiteralPath $imgFile)) {
                    $idx = [int]$monIdxStr
                    # Find matching monitor by 0-based or 1-based index
                    $targetMon = $null
                    if ($idx -lt $activeMons.Count) {
                        $targetMon = $activeMons[$idx]
                    } elseif (($idx - 1) -lt $activeMons.Count -and ($idx - 1) -ge 0) {
                        $targetMon = $activeMons[$idx - 1]
                    }

                    if ($targetMon) {
                        # Check if adjustments are defined for this monitor
                        $adj = $null
                        if ($wCfg.Adjustments -and $wCfg.Adjustments.PSObject.Properties[$monIdxStr]) {
                            $adj = $wCfg.Adjustments.$monIdxStr
                        }

                        $targetW = [Math]::Max(100, $targetMon.Right - $targetMon.Left)
                        $targetH = [Math]::Max(100, $targetMon.Bottom - $targetMon.Top)

                        $scaleP = if ($adj -and $adj.ScalePercent) { [double]$adj.ScalePercent } else { 100.0 }
                        $hasTransformation = ($adj -and (
                            ($adj.OffsetX -and [int]$adj.OffsetX -ne 0) -or
                            ($adj.OffsetY -and [int]$adj.OffsetY -ne 0) -or
                            ($scaleP -ne 100.0) -or
                            ($adj.FlipH -and [bool]$adj.FlipH) -or
                            ($adj.FlipV -and [bool]$adj.FlipV) -or
                            ($adj.BgColor -and $adj.BgColor -ne "#000000" -and $adj.BgColor -ne "#000")
                        ))

                        if ($hasTransformation) {
                            $cleanProf = ($ProfileItem.Name -replace '[^a-zA-Z0-9_\-]', '_')
                            # Unique filename per transform parameter to avoid stale cache hits
                            $hashKey = "$($adj.OffsetX)_$($adj.OffsetY)_$($scaleP)_$($adj.FlipH)_$($adj.FlipV)_$($adj.BgColor)_$($wCfg.Position)"
                            $hash = [Math]::Abs($hashKey.GetHashCode())
                            $renderedOut = Join-Path $cacheDir "${cleanProf}_mon${monIdxStr}_${hash}.png"
                            $appliedImg = New-TransformedWallpaper -SourcePath $imgFile -TargetWidth $targetW -TargetHeight $targetH -SizingMode $wCfg.Position -OffsetX ([int]$adj.OffsetX) -OffsetY ([int]$adj.OffsetY) -ScalePercent $scaleP -FlipH ([bool]$adj.FlipH) -FlipV ([bool]$adj.FlipV) -BgColorHex $adj.BgColor -OutputPath $renderedOut
                            if ($appliedImg) {
                                # When applying pre-rendered transformed image, use Fill (4) so it fills the monitor exactly without distortion
                                [DesktopWallpaperNative]::ApplyWallpaper($targetMon.Path, $appliedImg, 4) | Out-Null
                                continue
                            }
                        }

                        # Normal native apply
                        [DesktopWallpaperNative]::ApplyWallpaper($targetMon.Path, $imgFile, $posCode) | Out-Null
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to set profile wallpapers: $_"
    }
}

# Function to toggle USB hardware devices defined in profile
function Sync-ProfileDevices {
    param($ProfileItem, $LiveConfig)
    if (-not $ProfileItem.Devices -or -not $LiveConfig.DeviceDefinitions) { return }

    $targetList = @()
    foreach ($devKey in $ProfileItem.Devices.PSObject.Properties.Name) {
        $shouldEnable = [bool]$ProfileItem.Devices.$devKey
        $def = $LiveConfig.DeviceDefinitions.$devKey
        if ($def -and $def.InstanceId) {
            $targetList += [PSCustomObject]@{
                Key        = $devKey
                Name       = $def.Name
                InstanceId = $def.InstanceId
                Enabled    = $shouldEnable
            }
        }
    }

    if ($targetList.Count -eq 0) { return }

    # Read configurable advanced timing settings (or fall back to defaults)
    $adv = $LiveConfig.AdvancedSettings
    $usbDelay = if ($adv -and $adv.UsbToggleDelayMs) { [int]$adv.UsbToggleDelayMs } else { 250 }
    $prioritizeHub = if ($adv -and ($adv.PSObject.Properties["PrioritizeHubOrder"])) { [bool]$adv.PrioritizeHubOrder } else { $true }
    $purgePhantom = if ($adv -and ($adv.PSObject.Properties["PurgePhantomUsbDevices"])) { [bool]$adv.PurgePhantomUsbDevices } else { $true }

    # Order device toggling: disable downstream devices and hubs gracefully,
    # or enable hubs first so downstream peripherals can enumerate properly.
    if ($prioritizeHub) {
        $sortedList = $targetList | Sort-Object -Property @{
            Expression = {
                if ($_.Enabled) {
                    # Enabling: Hubs first (priority 0), then downstream devices (priority 1)
                    if ($_.Key -eq "SimRigHub") { 0 } else { 1 }
                } else {
                    # Disabling: Downstream devices first (priority 0), hubs last (priority 1)
                    if ($_.Key -eq "SimRigHub") { 1 } else { 0 }
                }
            }
        }
    } else {
        $sortedList = $targetList
    }

    # Bulk query present PnP devices once (~500ms) rather than 8 separate slow queries
    $pnpMap = @{}
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $pnpMap[$_.InstanceId] = $_.Status }

    foreach ($dev in $sortedList) {
        $id = $dev.InstanceId
        if (-not $pnpMap.ContainsKey($id)) {
            continue
        }

        $isCurrentlyEnabled = ($pnpMap[$id] -eq "OK")

        try {
            if ($dev.Enabled -and -not $isCurrentlyEnabled) {
                # Turn ON via pnputil
                & pnputil.exe /enable-device "$id" | Out-Null
                Start-Sleep -Milliseconds $usbDelay
            } elseif (-not $dev.Enabled -and $isCurrentlyEnabled) {
                # Turn OFF via pnputil
                & pnputil.exe /disable-device "$id" | Out-Null
                Start-Sleep -Milliseconds $usbDelay
            }
        } catch {
            # Continue on error so other devices still toggle
        }
    }

    # If pedals are enabled, restart/re-enumerate them automatically to prevent USB suspend hang
    $tLcm = $targetList | Where-Object { $_.Key -eq "TLCMPedals" -and $_.Enabled }
    if ($tLcm) {
        try {
            & pnputil.exe /restart-device "USB\VID_044F&PID_B371*" | Out-Null
        } catch {}
    } elseif ($purgePhantom) {
        # When switching away from Racing Rig to Desktop, remove any crashed 'Unknown USB Device' descriptor nodes
        try {
            & pnputil.exe /remove-device "USB\VID_0000&PID_0002\*" | Out-Null
        } catch {}
    }
}

# Function to execute a profile switch from embedded XmlConfig or File
function Invoke-ProfileSwitch {
    param($ProfileItem, $NotifyIcon = $null)
    $displayName = $ProfileItem.Name
    $nativeJson = Join-Path $configDir "$displayName.native.json"
    $hasNativeProfile = Test-Path -LiteralPath $nativeJson

    Write-Host "Switching displays to: $displayName" -ForegroundColor Green

    # 2. Smart Plug Power Pre-sequencing
    # If switching from dual screens to a subset single screen (or vice versa),
    # the physical displays are already powered and connected - zero delay and zero plug action needed!
    $adv = $initialConfig.AdvancedSettings
    $plugDelay = if ($adv -and $adv.PreSwitchPlugDelayMs) { [int]$adv.PreSwitchPlugDelayMs } else { 800 }
    $switchTimeout = if ($adv -and $adv.DisplaySwitchTimeoutSeconds) { [int]$adv.DisplaySwitchTimeoutSeconds * 1000 } else { 4000 }

    # Detect if target profile powers on external hardware (TV, Racing Rig)
    $hasPlugsToTurnOn = $false
    if ($ProfileItem.Plugs) {
        foreach ($plugVal in $ProfileItem.Plugs.PSObject.Properties.Value) {
            if ([bool]$plugVal) { $hasPlugsToTurnOn = $true; break }
        }
    }

    # If the target profile is a desk profile (subset of current desktop or local toggle), bypass plug sync completely!
    $isDeskProfile = ($displayName -like "*Desk*")
    $tapoRunner = Join-Path $profilesDir "scripts\tapo-runner.js"

    if (-not $isDeskProfile -and (Test-Path $tapoRunner)) {
        if ($hasPlugsToTurnOn) {
            Write-Host "Pre-syncing smart plugs for: $displayName..." -ForegroundColor Gray
            $plugSync = Start-Process -FilePath "node.exe" -ArgumentList "`"$tapoRunner`" sync `"$displayName`"" -WorkingDirectory $profilesDir -WindowStyle Hidden -Wait -PassThru
            Start-Sleep -Milliseconds $plugDelay
        } else {
            Start-Process -FilePath "node.exe" -ArgumentList "`"$tapoRunner`" sync `"$displayName`"" -WorkingDirectory $profilesDir -WindowStyle Hidden | Out-Null
        }
    }

    # 3. Apply display topology via NativeEngine.exe with timeout protection
    if ($hasNativeProfile) {
        Write-Host "Applying native Win32 CCD topology: $nativeJson" -ForegroundColor Cyan
        $proc = Start-Process -FilePath $nativeEngine -ArgumentList @("display", "apply", "`"$nativeJson`"") -WorkingDirectory $profilesDir -WindowStyle Hidden -PassThru
    } else {
        # Fallback or capture on the fly if needed
        $proc = Start-Process -FilePath $nativeEngine -ArgumentList @("display", "query") -WorkingDirectory $profilesDir -WindowStyle Hidden -PassThru
    }

    $finishedInTime = $proc.WaitForExit($switchTimeout)
    if (-not $finishedInTime) {
        Write-Warning "Display switch timed out after $($switchTimeout / 1000)s. Terminating process to prevent session lock."
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $exitCode = -999
    } else {
        $exitCode = $proc.ExitCode
    }
    
    # 4. Safety Gate: Only flip USB peripherals IF the display change succeeded!
    # If the monitor handshake or resolution change fails, DO NOT disable the user's controls.
    if ($exitCode -eq 0) {
        $liveCfg = Get-CurrentConfig
        Sync-ProfileDevices -ProfileItem $ProfileItem -LiveConfig $liveCfg
        Sync-ProfileAudio -ProfileItem $ProfileItem
        Sync-ProfileDisplayScales -ProfileItem $ProfileItem -AppRoot $profilesDir
        Sync-ProfileWallpapers -ProfileItem $ProfileItem
        Sync-ProfileLaunchApp -ProfileItem $ProfileItem

        # If switching away from single screen (e.g. to Dual, TV, Rig), reset single toggle state
        if ($displayName -notlike "*Single*") {
            $stateFile = Join-Path $configDir ".last_single_state"
            if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
        }

        if ($NotifyIcon) {
            $NotifyIcon.BalloonTipTitle = "Display Profile Swapped"
            $NotifyIcon.BalloonTipText = "Active: $displayName"
            $NotifyIcon.ShowBalloonTip(2000)
        }
    } else {
        $err = "Display switch failed (Exit code $exitCode) applying '$displayName'.`n`nUSB devices were NOT switched to prevent losing mouse/trackball control."
        Write-Error $err
        if ($NotifyIcon) {
            [System.Windows.Forms.MessageBox]::Show($err, "DeskShift Error", "OK", "Warning")
        }
    }
}

# Function to toggle / cycle between multiple monitor configurations (N-Way Toggle)
function Invoke-ProfileToggle {
    param(
        $ProfileItem = $null,
        $NotifyIcon = $null
    )

    $liveConfig = Get-CurrentConfig
    if (-not $ProfileItem) {
        # Default to Desk (Single Screen) if none passed
        $ProfileItem = $liveConfig.Profiles | Where-Object { $_.IsToggle } | Select-Object -First 1
    }
    if (-not $ProfileItem) {
        Write-Error "No toggle profile defined in $ConfigFile"
        return
    }

    # Determine toggle cycle list
    $cycle = @()
    if ($ProfileItem.ToggleCycle -and $ProfileItem.ToggleCycle.Count -gt 0) {
        $cycle = @($ProfileItem.ToggleCycle)
    } else {
        # Fallback to standard 2-way toggle
        $cycle = @("Desk (Single Right)", "Desk (Single Left)")
    }

    Add-Type -AssemblyName System.Windows.Forms
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $cleanSafeName = ($ProfileItem.Name -replace '[^a-zA-Z0-9_\-]', '_')
    $stateFile = Join-Path $configDir ".last_toggle_$cleanSafeName"
    $lastIndex = -1
    if (Test-Path -LiteralPath $stateFile) {
        $raw = (Get-Content -LiteralPath $stateFile -Raw).Trim()
        [int]::TryParse($raw, [ref]$lastIndex) | Out-Null
    }

    # If currently not in single-screen mode (or first time running), start at step 0
    if ($screens.Count -ne 1 -or $lastIndex -lt 0 -or $lastIndex -ge $cycle.Count) {
        $nextIndex = 0
    } else {
        # Advance modulo N
        $nextIndex = ($lastIndex + 1) % $cycle.Count
    }

    $targetProfileName = $cycle[$nextIndex]
    [System.IO.File]::WriteAllText($stateFile, $nextIndex.ToString(), [System.Text.Encoding]::UTF8)

    $targetItem = $liveConfig.Profiles | Where-Object { $_.Name -eq $targetProfileName -or $_.Label -eq $targetProfileName } | Select-Object -First 1
    if ($targetItem) {
        Write-Host "Toggle Cycle [$($nextIndex + 1)/$($cycle.Count)]: Switching to '$($targetItem.Name)'" -ForegroundColor Cyan
        Invoke-ProfileSwitch -ProfileItem $targetItem -NotifyIcon $NotifyIcon
    } else {
        $err = "Cycle target profile '$targetProfileName' not found in $ConfigFile"
        Write-Error $err
        if ($NotifyIcon) { [System.Windows.Forms.MessageBox]::Show($err, "Display Switcher Error", "OK", "Error") }
    }
}

function Invoke-SingleScreenToggle {
    param($NotifyIcon = $null)
    Invoke-ProfileToggle -NotifyIcon $NotifyIcon
}

# Function to capture live displays into profiles.json
function Save-CurrentLayoutAsProfile {
    param([string]$TargetName, [string]$TargetLabel = "", $NotifyIcon = $null)

    $targetJson = Join-Path $configDir "$TargetName.native.json"
    $p = Start-Process -FilePath $nativeEngine -ArgumentList @("display", "capture", "`"$TargetName`"", "`"$targetJson`"") -WorkingDirectory $profilesDir -WindowStyle Hidden -Wait -PassThru

    if (-not (Test-Path -LiteralPath $targetJson)) {
        $err = "Failed to query active monitors from NativeEngine (ExitCode: $($p.ExitCode))."
        Write-Error $err
        if ($NotifyIcon) { [System.Windows.Forms.MessageBox]::Show($err, "Capture Error", "OK", "Error") }
        return $false
    }

    $xmlText = [System.IO.File]::ReadAllText($tempCapture, [System.Text.Encoding]::UTF8)
    Remove-Item -LiteralPath $tempCapture -Force

    $cfg = Get-CurrentConfig
    if (-not $cfg) { return $false }

    $existing = $cfg.Profiles | Where-Object { $_.Name -eq $TargetName } | Select-Object -First 1

    if ($existing) {
        $existing.XmlConfig = $xmlText
        if ($TargetLabel) { $existing.Label = $TargetLabel }
    } else {
        $newObj = [PSCustomObject]@{
            Name      = $TargetName
            Label     = if ($TargetLabel) { $TargetLabel } else { $TargetName }
            Devices   = [PSCustomObject]@{
                VRHeadset = $false
                Loupedeck = $true
                SimRigHub = $false
            }
            XmlConfig = $xmlText
        }
        $cfg.Profiles += $newObj
    }

    $updatedJson = $cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigFile, $updatedJson, [System.Text.Encoding]::UTF8)

    Write-Host "Saved current layout as '$TargetName' into $ConfigFile" -ForegroundColor Green
    if ($NotifyIcon) {
        $NotifyIcon.BalloonTipTitle = "Display Profile Saved"
        $NotifyIcon.BalloonTipText = "Layout captured as '$TargetName'"
        $NotifyIcon.ShowBalloonTip(2500)
    }
    return $true
}

# 2. Handle CLI -Capture Argument
if ($Capture) {
    $ok = Save-CurrentLayoutAsProfile -TargetName $Capture
    if ($ok) { exit 0 } else { exit 1 }
}

# 3. Handle CLI -List Argument
if ($List) {
    Write-Host "`nAvailable Display Profiles (from $ConfigFile):" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------"
    foreach ($p in $initialConfig.Profiles) {
        if (-not $p.Separator -and -not $p.Hidden) {
            Write-Host ("  {0,-25} ({1})" -f $p.Name, $p.Label)
        }
    }
    Write-Host "--------------------------------------------------------"
    exit 0
}

# 4. Handle CLI Direct Profile Argument or Toggle (e.g. for Loupedeck)
if ($Single -or $Toggle -or ($ProfileName -and $ProfileName -match "^(single|toggle|desk\s*\(single)")) {
    Invoke-SingleScreenToggle
    exit 0
}

if ($ProfileName) {
    $match = $initialConfig.Profiles | Where-Object { $_.Name -like "*$ProfileName*" -or $_.Label -like "*$ProfileName*" } | Select-Object -First 1
    if ($match) {
        if ($match.IsToggle) {
            Invoke-ProfileToggle -ProfileItem $match
        } else {
            Invoke-ProfileSwitch -ProfileItem $match
        }
        exit 0
    } else {
        Write-Error "No profile found matching '$ProfileName'. Use -List to view available profiles."
        exit 1
    }
}

# Default behavior when run with no arguments: Start System Tray
if (-not $ProfileName -and -not $Tray -and -not $List -and -not $Capture -and -not $Single -and -not $Toggle) {
    $Tray = $true
}

# 5. Handle System Tray GUI Mode (-Tray)
if ($Tray) {
    # Terminate any stale existing -Tray instances to prevent invisible zombie processes
    $currentPid = $PID
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $currentPid -and $_.CommandLine -match "DeskShift\.ps1.*-Tray"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

    # Boot resiliency: Wait for storage drive and config file to mount
    $configDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ConfigFile) -and ([DateTime]::UtcNow -lt $configDeadline)) {
        Start-Sleep -Seconds 1
    }

    # Boot resiliency: Wait for Windows Explorer shell to be active
    $shellDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and ([DateTime]::UtcNow -lt $shellDeadline)) {
        Start-Sleep -Seconds 1
    }
    Start-Sleep -Seconds 2

    # Verify Web Remote Windows Service is running IF enabled in configuration
    try {
        $webEnabled = if ($initialConfig.WebRemote -and ($null -ne $initialConfig.WebRemote.Enabled)) { [bool]$initialConfig.WebRemote.Enabled } else { $true }
        $task = Get-ScheduledTask -TaskName "DisplaySwitcherWebRemote" -ErrorAction SilentlyContinue
        if ($task) {
            if ($webEnabled -and $task.State -ne "Running") {
                Start-ScheduledTask -TaskName "DisplaySwitcherWebRemote" -ErrorAction SilentlyContinue
            } elseif (-not $webEnabled -and $task.State -eq "Running") {
                Stop-ScheduledTask -TaskName "DisplaySwitcherWebRemote" -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic

    # Compile TaskbarCreated message listener so tray icon survives Explorer restarts
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
    using System;
    using System.Windows.Forms;
    using System.Runtime.InteropServices;

    public class TaskbarMessageFilter : IMessageFilter
    {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern uint RegisterWindowMessage(string lpString);

        private uint msgId;
        private Action callback;

        public TaskbarMessageFilter(Action cb)
        {
            callback = cb;
            msgId = RegisterWindowMessage("TaskbarCreated");
        }

        public bool PreFilterMessage(ref Message m)
        {
            if (msgId != 0 && m.Msg == (int)msgId)
            {
                if (callback != null) callback();
            }
            return false;
        }
    }
"@ -ErrorAction SilentlyContinue

    $notify = New-Object System.Windows.Forms.NotifyIcon
    
    $iconName = if ($initialConfig.IconFile) { $initialConfig.IconFile } else { "monitor_exact_taskbar.ico" }
    $iconFullPath = Join-Path $iconsDir $iconName
    if (-not (Test-Path -LiteralPath $iconFullPath)) {
        $iconFullPath = Join-Path $profilesDir $iconName
    }

    if (Test-Path -LiteralPath $iconFullPath) {
        $notify.Icon = New-Object System.Drawing.Icon($iconFullPath, [System.Windows.Forms.SystemInformation]::SmallIconSize)
    } else {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
    }

    $notify.Text = "Display Profile Switcher (RTX 5080)"
    $notify.Visible = $true

    # Register TaskbarCreated filter to re-display icon if Explorer restarts
    $taskbarFilter = New-Object TaskbarMessageFilter([Action]{
        $notify.Visible = $false
        Start-Sleep -Milliseconds 250
        $notify.Visible = $true
    })
    [System.Windows.Forms.Application]::AddMessageFilter($taskbarFilter)

    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $contextMenu.ShowImageMargin = $false
    $contextMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    # Function to populate the menu dynamically every time it opens
    $populateMenu = {
        $contextMenu.Items.Clear()

        # Read latest profiles.json directly from disk
        $liveConfig = Get-CurrentConfig
        if (-not $liveConfig) { return }

        # 1. Main Display Profiles List from JSON
        foreach ($item in $liveConfig.Profiles) {
            if ($item.Separator) {
                $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
            } elseif ($item.Hidden) {
                continue
            } else {
                $targetLabel = if ($item.Label) { $item.Label } else { $item.Name }
                $menuItem = $contextMenu.Items.Add($targetLabel)
                $menuItem.Tag = $item
                $menuItem.add_Click({
                    param($sender, $e)
                    if ($sender.Tag.IsToggle) {
                        Invoke-ProfileToggle -ProfileItem $sender.Tag -NotifyIcon $notify
                    } else {
                        Invoke-ProfileSwitch -ProfileItem $sender.Tag -NotifyIcon $notify
                    }
                })
            }
        }

        $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        # Configure DeskShift Menu Item
        $usbItem = $contextMenu.Items.Add("⚙️ Configure DeskShift...")
        $usbItem.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
        $usbItem.add_Click({
            param($sender, $e)
            # Guard against spamming multiple windows if already running or loading
            $running = Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -match "DeskShift" -and $_.MainWindowHandle -ne [IntPtr]::Zero
            }
            if ($running) {
                # Bring existing window to front
                Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinUtil {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue
                [WinUtil]::ShowWindow($running[0].MainWindowHandle, 9) | Out-Null
                [WinUtil]::SetForegroundWindow($running[0].MainWindowHandle) | Out-Null
                return
            }

            $usbGuiScript = Join-Path $profilesDir "Configure-DeskShift.ps1"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$usbGuiScript`""
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        })

        # Launch/View Web Remote Dashboard Menu Item (only if enabled)
        $webEnabled = if ($liveConfig.WebRemote -and ($null -ne $liveConfig.WebRemote.Enabled)) { [bool]$liveConfig.WebRemote.Enabled } else { $true }
        if ($webEnabled) {
            $webItem = $contextMenu.Items.Add("📱 Open Web Remote Dashboard")
            $webItem.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
            $webItem.add_Click({
                $port = if ($liveConfig.WebRemote -and $liveConfig.WebRemote.Port) { $liveConfig.WebRemote.Port } else { 8088 }
                Start-Process "http://127.0.0.1:$port"
            })
        }

        $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        # Exit Button
        $exitItem = $contextMenu.Items.Add("Exit DeskShift")
        $exitItem.add_Click({
            $notify.Visible = $false
            $notify.Dispose()
            [System.Windows.Forms.Application]::Exit()
        })
    }

    # Rebuild dynamically whenever the menu is about to be displayed
    $contextMenu.add_Opening({
        param($sender, $e)
        & $populateMenu
    })

    # Initial build
    & $populateMenu

    $notify.ContextMenuStrip = $contextMenu

    # Open on left click as well as right click
    $notify.add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $method = [System.Windows.Forms.NotifyIcon].GetMethod("ShowContextMenu", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
            if ($method) { $method.Invoke($notify, $null) }
        }
    })

    [System.Windows.Forms.Application]::Run()
}
