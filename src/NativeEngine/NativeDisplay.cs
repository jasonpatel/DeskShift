using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace NativeDisplay {
    #region Win32 CCD Enums & Structs

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

    public static class DisplayApi {
        [DllImport("user32.dll")]
        public static extern StatusCode GetDisplayConfigBufferSizes(
            QueryDisplayFlags flags,
            out uint numPathArrayElements,
            out uint numModeInfoArrayElements
        );

        [DllImport("user32.dll")]
        public static extern StatusCode QueryDisplayConfig(
            QueryDisplayFlags flags,
            ref uint numPathArrayElements,
            [Out] DisplayConfigPathInfo[] pathInfoArray,
            ref uint numModeInfoArrayElements,
            [Out] DisplayConfigModeInfo[] modeInfoArray,
            IntPtr currentTopologyId
        );

        [DllImport("user32.dll")]
        public static extern StatusCode SetDisplayConfig(
            uint numPathArrayElements,
            [In] DisplayConfigPathInfo[] pathArray,
            uint numModeInfoArrayElements,
            [In] DisplayConfigModeInfo[] modeInfoArray,
            SetDisplayConfigFlags flags
        );

        [DllImport("user32.dll")]
        public static extern StatusCode DisplayConfigGetDeviceInfo(ref DisplayConfigTargetDeviceName requestPacket);

        public static string GetMonitorName(LUID adapterId, uint targetId) {
            DisplayConfigTargetDeviceName deviceName = new DisplayConfigTargetDeviceName();
            deviceName.header.size = (uint)Marshal.SizeOf(typeof(DisplayConfigTargetDeviceName));
            deviceName.header.adapterId = adapterId;
            deviceName.header.id = targetId;
            deviceName.header.type = DisplayConfigDeviceInfoType.GetTargetName;

            StatusCode status = DisplayConfigGetDeviceInfo(ref deviceName);
            if (status == StatusCode.Success && !string.IsNullOrEmpty(deviceName.monitorFriendlyDeviceName)) {
                return deviceName.monitorFriendlyDeviceName;
            }
            return "Monitor_" + targetId;
        }
    }

    #region Serialization DTOs

    public class DisplayLayoutSnapshot {
        public string ProfileName { get; set; }
        public DateTime CapturedAt { get; set; }
        public int PathCount { get; set; }
        public int ModeCount { get; set; }
        public List<DisplayMonitorDTO> Monitors { get; set; }
        public string RawPathsBase64 { get; set; }
        public string RawModesBase64 { get; set; }

        public DisplayLayoutSnapshot() {
            Monitors = new List<DisplayMonitorDTO>();
        }
    }

    public class DisplayMonitorDTO {
        public string Name { get; set; }
        public uint TargetId { get; set; }
        public uint SourceId { get; set; }
        public int PositionX { get; set; }
        public int PositionY { get; set; }
        public uint Width { get; set; }
        public uint Height { get; set; }
        public double RefreshRateHz { get; set; }
        public string Orientation { get; set; }
        public string OutputTech { get; set; }
    }

    #endregion

    public static class Engine {
        public static DisplayLayoutSnapshot CaptureCurrentLayout(string profileName) {
            uint pathCount = 0;
            uint modeCount = 0;

            StatusCode status = DisplayApi.GetDisplayConfigBufferSizes(QueryDisplayFlags.OnlyActivePaths, out pathCount, out modeCount);
            if (status != StatusCode.Success) {
                throw new InvalidOperationException("Failed to get display buffer sizes. Win32 code: " + status);
            }

            DisplayConfigPathInfo[] paths = new DisplayConfigPathInfo[pathCount];
            DisplayConfigModeInfo[] modes = new DisplayConfigModeInfo[modeCount];

            status = DisplayApi.QueryDisplayConfig(QueryDisplayFlags.OnlyActivePaths, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            if (status != StatusCode.Success) {
                throw new InvalidOperationException("Failed to query active display configuration. Win32 code: " + status);
            }

            // Trim arrays to exact returned count
            Array.Resize(ref paths, (int)pathCount);
            Array.Resize(ref modes, (int)modeCount);

            DisplayLayoutSnapshot snapshot = new DisplayLayoutSnapshot();
            snapshot.ProfileName = profileName;
            snapshot.CapturedAt = DateTime.UtcNow;
            snapshot.PathCount = (int)pathCount;
            snapshot.ModeCount = (int)modeCount;

            // Extract readable monitor info
            for (int i = 0; i < pathCount; i++) {
                var p = paths[i];
                var m = new DisplayMonitorDTO();
                m.TargetId = p.targetInfo.id;
                m.SourceId = p.sourceInfo.id;
                m.Name = DisplayApi.GetMonitorName(p.targetInfo.adapterId, p.targetInfo.id);
                m.OutputTech = p.targetInfo.outputTechnology.ToString();
                m.Orientation = p.targetInfo.rotation.ToString();

                if (p.targetInfo.refreshRate.Denominator > 0) {
                    m.RefreshRateHz = Math.Round((double)p.targetInfo.refreshRate.Numerator / p.targetInfo.refreshRate.Denominator, 2);
                }

                if (p.sourceInfo.modeInfoIdx < modes.Length) {
                    var sm = modes[p.sourceInfo.modeInfoIdx].modeInfo.sourceMode;
                    m.Width = sm.width;
                    m.Height = sm.height;
                    m.PositionX = sm.position.x;
                    m.PositionY = sm.position.y;
                }

                snapshot.Monitors.Add(m);
            }

            // Binary serialize exact Win32 structures for 100% loss-free atomic re-application
            snapshot.RawPathsBase64 = StructArrayToBase64(paths);
            snapshot.RawModesBase64 = StructArrayToBase64(modes);

            return snapshot;
        }

        public static StatusCode ApplyLayout(DisplayLayoutSnapshot snapshot) {
            if (string.IsNullOrEmpty(snapshot.RawPathsBase64) || string.IsNullOrEmpty(snapshot.RawModesBase64)) {
                throw new ArgumentException("Snapshot does not contain raw Win32 CCD buffer payloads.");
            }

            DisplayConfigPathInfo[] paths = Base64ToStructArray<DisplayConfigPathInfo>(snapshot.RawPathsBase64, snapshot.PathCount);
            DisplayConfigModeInfo[] modes = Base64ToStructArray<DisplayConfigModeInfo>(snapshot.RawModesBase64, snapshot.ModeCount);

            SetDisplayConfigFlags flags = SetDisplayConfigFlags.Apply |
                                          SetDisplayConfigFlags.AllowChanges |
                                          SetDisplayConfigFlags.UseSuppliedDisplayConfig |
                                          SetDisplayConfigFlags.SaveToDatabase;

            return DisplayApi.SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, flags);
        }

        #region Struct Byte Marshalling Helpers

        private static string StructArrayToBase64<T>(T[] array) where T : struct {
            int structSize = Marshal.SizeOf(typeof(T));
            byte[] bytes = new byte[structSize * array.Length];
            GCHandle handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            try {
                IntPtr ptr = handle.AddrOfPinnedObject();
                for (int i = 0; i < array.Length; i++) {
                    Marshal.StructureToPtr(array[i], new IntPtr(ptr.ToInt64() + (i * structSize)), false);
                }
            } finally {
                handle.Free();
            }
            return Convert.ToBase64String(bytes);
        }

        private static T[] Base64ToStructArray<T>(string base64, int count) where T : struct {
            byte[] bytes = Convert.FromBase64String(base64);
            int structSize = Marshal.SizeOf(typeof(T));
            T[] array = new T[count];
            GCHandle handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            try {
                IntPtr ptr = handle.AddrOfPinnedObject();
                for (int i = 0; i < count; i++) {
                    array[i] = (T)Marshal.PtrToStructure(new IntPtr(ptr.ToInt64() + (i * structSize)), typeof(T));
                }
            } finally {
                handle.Free();
            }
            return array;
        }

        #endregion
    }

    class Program {
        static int Main(string[] args) {
            if (args.Length < 2) {
                Console.WriteLine("Native Display Engine (Standalone Sandbox)");
                Console.WriteLine("Usage: NativeDisplay.exe capture <ProfileName> [output.json]");
                Console.WriteLine("       NativeDisplay.exe apply   <profile.json>");
                Console.WriteLine("       NativeDisplay.exe query");
                return 1;
            }

            string action = args[0].ToLower();
            string profileName = args[1];

            try {
                if (action == "capture") {
                    string outFile = args.Length > 2 ? args[2] : profileName + ".native.json";
                    var snapshot = Engine.CaptureCurrentLayout(profileName);

                    string json = SimpleJson(snapshot);
                    File.WriteAllText(outFile, json, Encoding.UTF8);

                    Console.WriteLine("Successfully captured display layout to: " + outFile);
                    Console.WriteLine("Active Monitors (" + snapshot.Monitors.Count + "):");
                    foreach (var m in snapshot.Monitors) {
                        Console.WriteLine(" - " + m.Name + " (" + m.Width + "x" + m.Height + " @ " + m.RefreshRateHz + "Hz) Pos: [" + m.PositionX + ", " + m.PositionY + "] Tech: " + m.OutputTech);
                    }
                    return 0;
                } else if (action == "apply") {
                    string inFile = profileName;
                    if (!File.Exists(inFile)) {
                        Console.Error.WriteLine("Error: File not found: " + inFile);
                        return 2;
                    }
                    string json = File.ReadAllText(inFile, Encoding.UTF8);
                    var snapshot = ParseJson(json);

                    Console.WriteLine("Applying profile: " + snapshot.ProfileName + " (" + snapshot.Monitors.Count + " monitors)...");
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    StatusCode status = Engine.ApplyLayout(snapshot);
                    sw.Stop();

                    if (status == StatusCode.Success) {
                        Console.WriteLine("Success! Display topology applied in " + sw.ElapsedMilliseconds + " ms.");
                        return 0;
                    } else {
                        Console.Error.WriteLine("Failed to apply topology. Win32 code: " + status);
                        return (int)status;
                    }
                } else if (action == "query") {
                    var snapshot = Engine.CaptureCurrentLayout("LiveQuery");
                    Console.WriteLine("Current Live Displays (" + snapshot.Monitors.Count + " active):");
                    foreach (var m in snapshot.Monitors) {
                        Console.WriteLine(" • " + m.Name + " | Res: " + m.Width + "x" + m.Height + " | Refresh: " + m.RefreshRateHz + "Hz | Pos: (" + m.PositionX + ", " + m.PositionY + ")");
                    }
                    return 0;
                } else {
                    Console.Error.WriteLine("Unknown action: " + action);
                    return 1;
                }
            } catch (Exception ex) {
                Console.Error.WriteLine("Fatal Error: " + ex.Message);
                return 99;
            }
        }

        #region Tiny In-Box JSON Serializer (No External Json.NET Required)

        static string SimpleJson(DisplayLayoutSnapshot s) {
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

        static DisplayLayoutSnapshot ParseJson(string json) {
            DisplayLayoutSnapshot s = new DisplayLayoutSnapshot();
            s.ProfileName = ExtractJsonValue(json, "ProfileName");
            s.PathCount = int.Parse(ExtractJsonValue(json, "PathCount"));
            s.ModeCount = int.Parse(ExtractJsonValue(json, "ModeCount"));
            s.RawPathsBase64 = ExtractJsonValue(json, "RawPathsBase64");
            s.RawModesBase64 = ExtractJsonValue(json, "RawModesBase64");
            return s;
        }

        static string ExtractJsonValue(string json, string key) {
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

        #endregion
    }
}
