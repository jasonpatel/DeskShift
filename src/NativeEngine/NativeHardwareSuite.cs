using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace NativeEngine {
    #region Win32 Display CCD Definitions

    public enum StatusCode : uint {
        Success = 0,
        InvalidParameter = 87,
        NotFound = 1168,
        NotSupported = 50,
        AccessDenied = 5,
        GenFailure = 31,
        BadConfiguration = 1610,
        Inuse = 170
    }

    [Flags]
    public enum QueryDisplayFlags : uint {
        Zero = 0x0,
        AllPaths = 0x00000001,
        OnlyActivePaths = 0x00000002,
        DatabaseCurrent = 0x00000004
    }

    [Flags]
    public enum SetDisplayConfigFlags : uint {
        Zero = 0x0,
        TopologyInternal = 0x00000001,
        TopologyClone = 0x00000002,
        TopologyExtend = 0x00000004,
        TopologyExternal = 0x00000008,
        TopologySupplied = 0x00000010,
        UseSuppliedDisplayConfig = 0x00000020,
        Validate = 0x00000040,
        Apply = 0x00000080,
        NoOptimization = 0x00000100,
        SaveToDatabase = 0x00000200,
        AllowChanges = 0x00000400,
        PathPersistIfRequired = 0x00000800,
        ForceModeEnumeration = 0x00001000,
        AllowPathOrderChanges = 0x00002000
    }

    public enum DisplayConfigVideoOutputTechnology : uint {
        Other = 0xFFFFFFFF,
        Hd15 = 0,
        Svideo = 1,
        CompositeVideo = 2,
        ComponentVideo = 3,
        Dvi = 4,
        Hdmi = 5,
        Lvds = 6,
        D_Jpn = 8,
        Sdi = 9,
        DisplayPortExternal = 10,
        DisplayPortEmbedded = 11,
        UdiExternal = 12,
        UdiEmbedded = 13,
        Sdtvdongle = 14,
        Miracast = 15,
        IndirectWired = 16,
        Internal = 0x80000000,
        Uninitialized = 0xFFFFFFFF
    }

    public enum DisplayConfigScanLineOrdering : uint {
        Unspecified = 0,
        Progressive = 1,
        Interlaced = 2,
        InterlacedUpperFieldFirst = Interlaced,
        InterlacedLowerFieldFirst = 3
    }

    public enum DisplayConfigRotation : uint {
        Zero = 0,
        Identity = 1,
        Rotate90 = 2,
        Rotate180 = 3,
        Rotate270 = 4
    }

    public enum DisplayConfigScaling : uint {
        Zero = 0,
        Identity = 1,
        Centered = 2,
        Stretched = 3,
        AspectRatioCenteredMax = 4,
        Custom = 5,
        Preferred = 6
    }

    public enum DisplayConfigPixelFormat : uint {
        Zero = 0,
        Pixel8Bpp = 1,
        Pixel16Bpp = 2,
        Pixel24Bpp = 3,
        Pixel32Bpp = 4,
        NonGdi = 5
    }

    public enum DisplayConfigModeInfoType : uint {
        Zero = 0,
        Source = 1,
        Target = 2,
        DesktopImage = 3
    }

    public enum DisplayConfigDeviceInfoType : uint {
        GetSourceName = 1,
        GetTargetName = 2,
        GetTargetPreferredMode = 3,
        GetAdapterName = 4,
        SetTargetPersistence = 5,
        GetTargetBaseType = 6,
        GetSupportVirtualResolution = 7,
        SetSupportVirtualResolution = 8,
        GetAdvancedColorInfo = 9,
        SetAdvancedColorState = 10,
        GetSdrWhiteLevel = 11
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigRational {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigPathSourceInfo {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigPathTargetInfo {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public DisplayConfigVideoOutputTechnology outputTechnology;
        public DisplayConfigRotation rotation;
        public DisplayConfigScaling scaling;
        public DisplayConfigRational refreshRate;
        public DisplayConfigScanLineOrdering scanLineOrdering;
        public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigPathInfo {
        public DisplayConfigPathSourceInfo sourceInfo;
        public DisplayConfigPathTargetInfo targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigSourceMode {
        public uint width;
        public uint height;
        public DisplayConfigPixelFormat pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfig2DRegion {
        public uint cx;
        public uint cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigVideoSignalInfo {
        public ulong pixelRate;
        public DisplayConfigRational hSyncFreq;
        public DisplayConfigRational vSyncFreq;
        public DisplayConfig2DRegion activeSize;
        public DisplayConfig2DRegion totalSize;
        public uint videoStandard;
        public DisplayConfigScanLineOrdering scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigTargetMode {
        public DisplayConfigVideoSignalInfo targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigDesktopImageInfo {
        public POINTL PathSourceSize;
        public int DesktopImageRegionLeft;
        public int DesktopImageRegionTop;
        public int DesktopImageRegionRight;
        public int DesktopImageRegionBottom;
        public int DesktopImageClipLeft;
        public int DesktopImageClipTop;
        public int DesktopImageClipRight;
        public int DesktopImageClipBottom;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DisplayConfigModeInfoUnion {
        [FieldOffset(0)]
        public DisplayConfigTargetMode targetMode;
        [FieldOffset(0)]
        public DisplayConfigSourceMode sourceMode;
        [FieldOffset(0)]
        public DisplayConfigDesktopImageInfo desktopImageInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigModeInfo {
        public DisplayConfigModeInfoType infoType;
        public uint id;
        public LUID adapterId;
        public DisplayConfigModeInfoUnion modeInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DisplayConfigDeviceInfoHeader {
        public DisplayConfigDeviceInfoType type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DisplayConfigTargetDeviceName {
        public DisplayConfigDeviceInfoHeader header;
        public uint flags;
        public DisplayConfigVideoOutputTechnology outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    #endregion

    #region Win32 Audio COM Definitions (IPolicyConfig & CoreAudio)

    public enum ERole {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2,
    }

    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig {
        [PreserveSig] int GetMixFormat();
        [PreserveSig] int GetDeviceFormat();
        [PreserveSig] int ResetDeviceFormat();
        [PreserveSig] int SetDeviceFormat();
        [PreserveSig] int GetProcessingPeriod();
        [PreserveSig] int SetProcessingPeriod();
        [PreserveSig] int GetShareMode();
        [PreserveSig] int SetShareMode();
        [PreserveSig] int GetPropertyValue();
        [PreserveSig] int SetPropertyValue();
        [PreserveSig] int SetDefaultEndpoint([In, MarshalAs(UnmanagedType.LPWStr)] string wszDeviceId, [In, MarshalAs(UnmanagedType.U4)] ERole eRole);
        [PreserveSig] int SetEndpointVisibility();
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    internal class CPolicyConfigClient { }

    #endregion

    #region Win32 SetupAPI & PnP Device Querying

    public static class PnpFastChecker {
        [DllImport("cfgmgr32.dll", EntryPoint = "CM_Locate_DevNodeW", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint CM_Locate_DevNode(out uint dnDevInst, string pDeviceID, uint ulFlags);

        [DllImport("cfgmgr32.dll", SetLastError = true)]
        public static extern uint CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, uint ulFlags);

        const uint CR_SUCCESS = 0x00000000;
        const uint DN_STARTED = 0x00000008;

        public static string CheckDeviceStatus(string instanceId) {
            uint devInst = 0;
            // 0x00000000 = CM_LOCATE_DEVNODE_NORMAL (only present devices)
            uint res = CM_Locate_DevNode(out devInst, instanceId, 0);
            if (res != CR_SUCCESS) {
                return "Disconnected";
            }

            uint status = 0;
            uint problem = 0;
            res = CM_Get_DevNode_Status(out status, out problem, devInst, 0);
            if (res == CR_SUCCESS) {
                if ((status & DN_STARTED) != 0 && problem == 0) {
                    return "ON (Active)";
                } else {
                    return "OFF (Disabled)";
                }
            }
            return "Disconnected";
        }
    }

    #endregion

    #region Audio Endpoint Manager

    public class AudioEndpointInfo {
        public string Id { get; set; }
        public string Name { get; set; }
        public bool IsDefault { get; set; }
    }

    public static class AudioController {
        public static bool SetDefaultAudioDevice(string deviceIdOrName) {
            try {
                // Find matching device ID from registry MMDevices
                string targetId = deviceIdOrName;
                if (!targetId.StartsWith("{")) {
                    var devices = GetAudioEndpoints();
                    foreach (var d in devices) {
                        if (d.Name.IndexOf(deviceIdOrName, StringComparison.OrdinalIgnoreCase) >= 0) {
                            targetId = d.Id;
                            break;
                        }
                    }
                }

                var policyConfig = (IPolicyConfig)new CPolicyConfigClient();
                policyConfig.SetDefaultEndpoint(targetId, ERole.eConsole);
                policyConfig.SetDefaultEndpoint(targetId, ERole.eMultimedia);
                policyConfig.SetDefaultEndpoint(targetId, ERole.eCommunications);
                return true;
            } catch (Exception) {
                return false;
            }
        }

        public static List<AudioEndpointInfo> GetAudioEndpoints() {
            var list = new List<AudioEndpointInfo>();
            try {
                using (var rootKey = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render")) {
                    if (rootKey == null) return list;

                    foreach (var subKeyName in rootKey.GetSubKeyNames()) {
                        using (var devKey = rootKey.OpenSubKey(subKeyName)) {
                            if (devKey == null) continue;
                            int state = Convert.ToInt32(devKey.GetValue("DeviceState", 0));
                            // State 1 = Active / Plugged In
                            if (state != 1) continue;

                            string friendlyName = "";
                            using (var props = devKey.OpenSubKey("Properties")) {
                                if (props != null) {
                                    // PKEY_Device_FriendlyName: {a45c254e-df1c-4efd-8020-67d146a850e0},14
                                    object val = props.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},14");
                                    if (val != null) friendlyName = val.ToString();
                                }
                            }

                            if (!string.IsNullOrEmpty(friendlyName)) {
                                list.Add(new AudioEndpointInfo {
                                    Id = subKeyName,
                                    Name = friendlyName,
                                    IsDefault = false
                                });
                            }
                        }
                    }
                }
            } catch { }
            return list;
        }
    }

    #endregion

    #region Standalone CLI / Dispatcher

    class Program {
        [STAThread]
        static int Main(string[] args) {
            if (args.Length < 1) {
                Console.WriteLine("Native Hardware & Audio Engine (Standalone Sandbox)");
                Console.WriteLine("Usage: NativeEngine.exe display query");
                Console.WriteLine("       NativeEngine.exe display capture <ProfileName> [file.json]");
                Console.WriteLine("       NativeEngine.exe display apply   <file.json>");
                Console.WriteLine("       NativeEngine.exe audio list");
                Console.WriteLine("       NativeEngine.exe audio set <DeviceNameOrId>");
                Console.WriteLine("       NativeEngine.exe pnp <InstanceId>");
                return 1;
            }

            string module = args[0].ToLower();

            if (module == "display") {
                string sub = args.Length > 1 ? args[1].ToLower() : "query";
                if (sub == "query") {
                    var s = NativeDisplay.Engine.CaptureCurrentLayout("LiveQuery");
                    Console.WriteLine("Current Live Displays (" + s.Monitors.Count + " active):");
                    foreach (var m in s.Monitors) {
                        Console.WriteLine(" • " + m.Name + " | Res: " + m.Width + "x" + m.Height + " | Refresh: " + m.RefreshRateHz + "Hz | Pos: (" + m.PositionX + ", " + m.PositionY + ")");
                    }
                    return 0;
                } else if (sub == "capture") {
                    string name = args.Length > 2 ? args[2] : "Current";
                    string file = args.Length > 3 ? args[3] : name + ".native.json";
                    var s = NativeDisplay.Engine.CaptureCurrentLayout(name);
                    File.WriteAllText(file, ProgramHelper.SimpleJson(s), Encoding.UTF8);
                    Console.WriteLine("Captured to: " + file);
                    return 0;
                } else if (sub == "apply") {
                    string file = args.Length > 2 ? args[2] : "";
                    if (!File.Exists(file)) { Console.Error.WriteLine("File not found: " + file); return 2; }
                    var s = ProgramHelper.ParseJson(File.ReadAllText(file, Encoding.UTF8));
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    var code = NativeDisplay.Engine.ApplyLayout(s);
                    sw.Stop();
                    Console.WriteLine("Applied in " + sw.ElapsedMilliseconds + " ms, Code: " + code);
                    return (int)code;
                }
            } else if (module == "audio") {
                string sub = args.Length > 1 ? args[1].ToLower() : "list";
                if (sub == "list") {
                    var list = AudioController.GetAudioEndpoints();
                    Console.WriteLine("Active Audio Endpoints (" + list.Count + "):");
                    foreach (var a in list) {
                        Console.WriteLine(" • " + a.Name + " [ID: " + a.Id + "]");
                    }
                    return 0;
                } else if (sub == "set") {
                    string target = args.Length > 2 ? args[2] : "";
                    bool ok = AudioController.SetDefaultAudioDevice(target);
                    Console.WriteLine(ok ? "Audio set to: " + target : "Failed to set audio device");
                    return ok ? 0 : 1;
                }
            } else if (module == "pnp") {
                string id = args.Length > 1 ? args[1] : "";
                var sw = System.Diagnostics.Stopwatch.StartNew();
                string status = PnpFastChecker.CheckDeviceStatus(id);
                sw.Stop();
                Console.WriteLine("Status: " + status + " (queried in " + sw.ElapsedMilliseconds + " ms)");
                return 0;
            }

            Console.Error.WriteLine("Unknown command");
            return 1;
        }
    }

    public static class ProgramHelper {
        public static string SimpleJson(NativeDisplay.DisplayLayoutSnapshot s) {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine("  \"ProfileName\": \"" + s.ProfileName + "\",");
            sb.AppendLine("  \"CapturedAt\": \"" + s.CapturedAt.ToString("o") + "\",");
            sb.AppendLine("  \"PathCount\": " + s.PathCount + ",");
            sb.AppendLine("  \"ModeCount\": " + s.ModeCount + ",");
            sb.AppendLine("  \"Monitors\": [");
            for (int i = 0; i < s.Monitors.Count; i++) {
                var m = s.Monitors[i];
                sb.AppendLine("    {");
                sb.AppendLine("      \"Name\": \"" + m.Name + "\",");
                sb.AppendLine("      \"TargetId\": " + m.TargetId + ",");
                sb.AppendLine("      \"SourceId\": " + m.SourceId + ",");
                sb.AppendLine("      \"PositionX\": " + m.PositionX + ",");
                sb.AppendLine("      \"PositionY\": " + m.PositionY + ",");
                sb.AppendLine("      \"Width\": " + m.Width + ",");
                sb.AppendLine("      \"Height\": " + m.Height + ",");
                sb.AppendLine("      \"RefreshRateHz\": " + m.RefreshRateHz + ",");
                sb.AppendLine("      \"Orientation\": \"" + m.Orientation + "\",");
                sb.AppendLine("      \"OutputTech\": \"" + m.OutputTech + "\"");
                sb.Append("    }");
                if (i < s.Monitors.Count - 1) sb.Append(",");
                sb.AppendLine();
            }
            sb.AppendLine("  ],");
            sb.AppendLine("  \"RawPathsBase64\": \"" + s.RawPathsBase64 + "\",");
            sb.AppendLine("  \"RawModesBase64\": \"" + s.RawModesBase64 + "\"");
            sb.AppendLine("}");
            return sb.ToString();
        }

        public static NativeDisplay.DisplayLayoutSnapshot ParseJson(string json) {
            var s = new NativeDisplay.DisplayLayoutSnapshot();
            s.ProfileName = ExtractJsonValue(json, "ProfileName");
            s.PathCount = int.Parse(ExtractJsonValue(json, "PathCount"));
            s.ModeCount = int.Parse(ExtractJsonValue(json, "ModeCount"));
            s.RawPathsBase64 = ExtractJsonValue(json, "RawPathsBase64");
            s.RawModesBase64 = ExtractJsonValue(json, "RawModesBase64");
            return s;
        }

        private static string ExtractJsonValue(string json, string key) {
            string pattern = "\"" + key + "\":";
            int idx = json.IndexOf(pattern);
            if (idx < 0) return "";
            int start = idx + pattern.Length;
            while (start < json.Length && (json[start] == ' ' || json[start] == '"')) start++;
            int end = start;
            if (json[start - 1] == '"') {
                while (end < json.Length && json[end] != '"') end++;
            } else {
                while (end < json.Length && json[end] != ',' && json[end] != '}' && json[end] != '\r' && json[end] != '\n') end++;
            }
            return json.Substring(start, end - start).Trim();
        }
    }

    #endregion
}
