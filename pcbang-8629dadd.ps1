# PC-bang gaming tweak kit - built bundle. Do not edit; edit src\ and run build.ps1.
param(
  [switch]$Revert,
  [switch]$DryRun,
  [switch]$NoNic,
  [switch]$NoDisplay,
  [switch]$NoIrq,
  [switch]$NoGpuIrq,
  [switch]$NoWatcher,
  [switch]$NoPause,
  [switch]$IdleDisable,
  [switch]$NoIdleDisable,
  [string[]]$SchemeCandidates = $null,
  [string]$DxPrefsPath = '',
  [string]$DxPrefsName = '',
  [string]$StateDir = "$env:ProgramData\pcbang-tune",
  [string]$GameName = 'League of Legends',
  [string[]]$SideNames = @('LeagueClientUx','LeagueClientUxRender','Riot Client','RiotClientServices','RiotClientCrashHandler'),
  # The game inherits its parent's affinity at birth, so the launcher is put on the game
  # mask BEFORE it spawns the game - the watcher's 2 s loop would only fix it afterwards.
  # Priority is deliberately not touched for these.
  [string[]]$ParentNames = @('LeagueClient'),
  [switch]$WatcherLoop,
  [uint64]$GameMask = 0,
  [uint64]$SideMask = 0,
  # Test-only: point the LoL cfg step at a throw-away Config dir instead of the real
  # C:\Riot Games\...\Config one.  Empty means "use the real install".
  [string]$LolCfgDir = '',
  [switch]$DotSource
)

# ==== begin nvidia.ps1 ====
# W-PCB2 - NVIDIA DRS module for the PC-bang kit.
# Pure Windows PowerShell 5.1, single file, ASCII only, no exe, no network.
#
# Public API (W-PCB1 codes against this contract):
#   Get-PcbNvLolState            -> Available / Profile / Error / Settings[{Id,Name,Value,UserSet}]
#   Set-PcbNvLol                 -> Ok / Before / After / Error
#   Restore-PcbNvLol -Before <s> -> Ok / After / Error
#
# Nothing here throws: every failure comes back as Available=$false / Ok=$false with an Error string.
# Private helpers are all prefixed PcbNv.
#
# Driver facts proven on this box (Windows 11, driver 32.0.15.8253, nvapi64.dll):
#   nvapi_QueryInterface(uint id) -> function pointer; DRS calls are cdecl.
#   NVDRS_SETTING is 12320 bytes, version word = 12320 | (1 << 16) = 0x00013020.
#   +4 name (UTF-16), +4100 settingId, +4108 settingLocation, +4112 isCurrentPredefined,
#   +4116 isPredefinedValid, +4124 predefined u32, +8220 current u32.
#   An override owned by the profile is settingLocation 0 with isCurrentPredefined 0.
#   DestroySession crashes the process if called twice on one handle, so the session
#   wrapper closes exactly once and never touches a handle it already released.

$script:PcbNvProfileName = 'League of Legends'
$script:PcbNvDllDefault = 'nvapi64.dll'

# The four latency settings, in contract order. Target is the value Set-PcbNvLol writes.
# W-NV2: the driver stores 0x00000000 in both V-Sync rows, which is in no advertised value
# list, so the two rows below write advertised values instead (see available.csv:505-513).
$script:PcbNvLolSettings = @(
    [pscustomobject]@{
        Id     = [uint32]::Parse('007BA09E', 'HexNumber')
        Name   = 'Maximum pre-rendered frames'
        Symbol = 'PRERENDERLIMIT'
        Target = [uint32]1
    },
    [pscustomobject]@{
        Id     = [uint32]::Parse('1057EB71', 'HexNumber')
        Name   = 'Power management mode'
        Symbol = 'PREFERRED_PSTATE'
        Target = [uint32]1
    },
    [pscustomobject]@{
        Id     = [uint32]::Parse('00A879CF', 'HexNumber')
        Name   = 'Vertical Sync'
        Symbol = 'VSYNCMODE'
        Target = [uint32]::Parse('08416747', 'HexNumber')
    },
    [pscustomobject]@{
        Id     = [uint32]::Parse('005A375C', 'HexNumber')
        Name   = 'Vertical Sync Tear Control'
        Symbol = 'VSYNCTEARCONTROL'
        Target = [uint32]::Parse('96861077', 'HexNumber')
    },
    # The other 12 settings the home PC writes to the same profile (drsapply.cpp:60-75,
    # W-INV2: all 16 live, every value below is either a listed value of that id or its
    # default, so the driver accepts each one).
    [pscustomobject]@{ Id = [uint32]::Parse('0064B541', 'HexNumber'); Name = 'Preferred refresh rate';           Symbol = 'REFRESHRATE';        Target = [uint32]1 },
    [pscustomobject]@{ Id = [uint32]::Parse('20C1221E', 'HexNumber'); Name = 'Threaded optimization';            Symbol = 'THREADEDOPTIMIZATION'; Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('201F619F', 'HexNumber'); Name = 'Buffer-flipping mode';             Symbol = 'FLIPMODE';           Target = [uint32]1 },
    [pscustomobject]@{ Id = [uint32]::Parse('20FDD1F9', 'HexNumber'); Name = 'Triple buffering';                 Symbol = 'TRIPLEBUFFERING';    Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('00198FFF', 'HexNumber'); Name = 'Shader Cache';                     Symbol = 'SHADERCACHE';        Target = [uint32]1 },
    [pscustomobject]@{ Id = [uint32]::Parse('101E61A9', 'HexNumber'); Name = 'Anisotropic filtering setting';    Symbol = 'ANISOTROPICFILTER';  Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('10D773D2', 'HexNumber'); Name = 'Antialiasing - Setting';           Symbol = 'AA_SETTING';         Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('107EFC5B', 'HexNumber'); Name = 'Antialiasing - Mode';              Symbol = 'AA_MODE';            Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('00E73211', 'HexNumber'); Name = 'Anisotropic sample optimization';  Symbol = 'ANISOSAMPLEOPT';     Target = [uint32]1 },
    [pscustomobject]@{ Id = [uint32]::Parse('00CE2691', 'HexNumber'); Name = 'Texture filtering - Quality';      Symbol = 'TEXFILTERQUALITY';   Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('0019BB68', 'HexNumber'); Name = 'Negative LOD bias';                Symbol = 'NEGATIVELODBIAS';    Target = [uint32]0 },
    [pscustomobject]@{ Id = [uint32]::Parse('10835002', 'HexNumber'); Name = 'Frame Rate Limiter';               Symbol = 'FRAMERATELIMITER';   Target = [uint32]0 }
)

$script:PcbNvCs = @'
using System;
using System.Runtime.InteropServices;

public sealed class PcbNvReadResult
{
    public uint Status;
    public uint Value;
    public bool UserSet;
    public string Name;
    public string Error;
}

public sealed class PcbNvSession : IDisposable
{
    public IntPtr Handle;
    public IntPtr Profile;
    public string Error;
    private bool closed;

    public bool Ok { get { return this.Error == null && this.Handle != IntPtr.Zero; } }

    // Exactly once. A second DestroySession on the same handle faults the process.
    public void Close()
    {
        if (this.closed) { return; }
        this.closed = true;
        IntPtr h = this.Handle;
        this.Handle = IntPtr.Zero;
        this.Profile = IntPtr.Zero;
        if (h != IntPtr.Zero) { PcbNvApi.Destroy(h); }
    }

    public void Dispose() { this.Close(); }
}

public static class PcbNvApi
{
    public const int SettingSize = 12320;
    public const uint StatusNotFound = 0xFFFFFF60u;

    private const uint IdInitialize = 0x0150E828u;
    private const uint IdCreateSession = 0x0694D52Eu;
    private const uint IdLoadSettings = 0x375DBD6Bu;
    private const uint IdSaveSettings = 0xFCBC7E14u;
    private const uint IdFindProfileByName = 0x7E4A9A0Bu;
    private const uint IdGetSetting = 0x73BF8338u;
    private const uint IdSetSetting = 0x577DD202u;
    private const uint IdDeleteProfileSetting = 0xE4A26362u;
    private const uint IdGetBaseProfile = 0xDA8466A0u;
    private const uint IdDestroySession = 0xDAD9CFF8u;

    private const int OffVersion = 0;
    private const int OffName = 4;
    private const int OffSettingId = 4100;
    private const int OffLocation = 4108;
    private const int OffIsCurrentPredefined = 4112;
    private const int OffIsPredefinedValid = 4116;
    private const int OffPredefinedValue = 4124;
    private const int OffCurrentValue = 8220;

    private const string ProfileName = "League of Legends";

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryW(string file);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr DelQueryInterface(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelInitialize();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelCreateSession(out IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelSessionOp(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelFindProfile(IntPtr session, [MarshalAs(UnmanagedType.LPWStr)] string name, out IntPtr profile);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelGetSetting(IntPtr session, IntPtr profile, uint id, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelSetSetting(IntPtr session, IntPtr profile, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelDeleteSetting(IntPtr session, IntPtr profile, uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint DelGetBaseProfile(IntPtr session, out IntPtr profile);

    private static string loadedDll;
    private static string loadError;
    private static DelInitialize fnInitialize;
    private static DelCreateSession fnCreateSession;
    private static DelSessionOp fnLoadSettings;
    private static DelSessionOp fnSaveSettings;
    private static DelSessionOp fnDestroySession;
    private static DelFindProfile fnFindProfile;
    private static DelGetSetting fnGetSetting;
    private static DelSetSetting fnSetSetting;
    private static DelDeleteSetting fnDeleteSetting;
    private static DelGetBaseProfile fnGetBaseProfile;

    private static string StatusText(string name, uint status)
    {
        return string.Format("{0} failed 0x{1:X8}", name, status);
    }

    private static string Missing(string name, uint id)
    {
        return string.Format("nvapi_QueryInterface({0}) is null for 0x{1:X8}", name, id);
    }

    private static void Zero(IntPtr buffer)
    {
        for (int i = 0; i < SettingSize; i += 4) { Marshal.WriteInt32(buffer, i, 0); }
    }

    // Returns null on success, otherwise the reason the API cannot be used.
    public static string EnsureLoaded(string dllName)
    {
        if (dllName == null || dllName.Length == 0) { dllName = "nvapi64.dll"; }
        if (loadedDll == dllName) { return loadError; }

        loadedDll = dllName;
        loadError = null;
        fnInitialize = null;
        fnCreateSession = null;
        fnLoadSettings = null;
        fnSaveSettings = null;
        fnDestroySession = null;
        fnFindProfile = null;
        fnGetSetting = null;
        fnSetSetting = null;
        fnDeleteSetting = null;
        fnGetBaseProfile = null;

        try
        {
            IntPtr module = LoadLibraryW(dllName);
            if (module == IntPtr.Zero) { loadError = "no nvapi64.dll"; return loadError; }

            IntPtr qi = GetProcAddress(module, "nvapi_QueryInterface");
            if (qi == IntPtr.Zero) { loadError = "no nvapi64.dll"; return loadError; }

            DelQueryInterface query = (DelQueryInterface)Marshal.GetDelegateForFunctionPointer(qi, typeof(DelQueryInterface));
            IntPtr p;

            p = query(IdInitialize);
            if (p == IntPtr.Zero) { loadError = Missing("Initialize", IdInitialize); return loadError; }
            fnInitialize = (DelInitialize)Marshal.GetDelegateForFunctionPointer(p, typeof(DelInitialize));

            p = query(IdCreateSession);
            if (p == IntPtr.Zero) { loadError = Missing("CreateSession", IdCreateSession); return loadError; }
            fnCreateSession = (DelCreateSession)Marshal.GetDelegateForFunctionPointer(p, typeof(DelCreateSession));

            p = query(IdLoadSettings);
            if (p == IntPtr.Zero) { loadError = Missing("LoadSettings", IdLoadSettings); return loadError; }
            fnLoadSettings = (DelSessionOp)Marshal.GetDelegateForFunctionPointer(p, typeof(DelSessionOp));

            p = query(IdSaveSettings);
            if (p == IntPtr.Zero) { loadError = Missing("SaveSettings", IdSaveSettings); return loadError; }
            fnSaveSettings = (DelSessionOp)Marshal.GetDelegateForFunctionPointer(p, typeof(DelSessionOp));

            p = query(IdFindProfileByName);
            if (p == IntPtr.Zero) { loadError = Missing("FindProfileByName", IdFindProfileByName); return loadError; }
            fnFindProfile = (DelFindProfile)Marshal.GetDelegateForFunctionPointer(p, typeof(DelFindProfile));

            p = query(IdGetSetting);
            if (p == IntPtr.Zero) { loadError = Missing("GetSetting", IdGetSetting); return loadError; }
            fnGetSetting = (DelGetSetting)Marshal.GetDelegateForFunctionPointer(p, typeof(DelGetSetting));

            p = query(IdSetSetting);
            if (p == IntPtr.Zero) { loadError = Missing("SetSetting", IdSetSetting); return loadError; }
            fnSetSetting = (DelSetSetting)Marshal.GetDelegateForFunctionPointer(p, typeof(DelSetSetting));

            p = query(IdDeleteProfileSetting);
            if (p == IntPtr.Zero) { loadError = Missing("DeleteProfileSetting", IdDeleteProfileSetting); return loadError; }
            fnDeleteSetting = (DelDeleteSetting)Marshal.GetDelegateForFunctionPointer(p, typeof(DelDeleteSetting));

            p = query(IdGetBaseProfile);
            if (p == IntPtr.Zero) { loadError = Missing("GetBaseProfile", IdGetBaseProfile); return loadError; }
            fnGetBaseProfile = (DelGetBaseProfile)Marshal.GetDelegateForFunctionPointer(p, typeof(DelGetBaseProfile));

            p = query(IdDestroySession);
            if (p == IntPtr.Zero) { loadError = Missing("DestroySession", IdDestroySession); return loadError; }
            fnDestroySession = (DelSessionOp)Marshal.GetDelegateForFunctionPointer(p, typeof(DelSessionOp));
        }
        catch (Exception ex)
        {
            loadError = "nvapi load failed: " + ex.Message;
        }
        return loadError;
    }

    public static void Destroy(IntPtr handle)
    {
        if (fnDestroySession == null || handle == IntPtr.Zero) { return; }
        try { fnDestroySession(handle); } catch { }
    }

    // Initialize -> CreateSession -> LoadSettings -> FindProfileByName.
    public static PcbNvSession Open()
    {
        PcbNvSession s = new PcbNvSession();
        try
        {
            if (fnInitialize == null) { s.Error = loadError != null ? loadError : "nvapi not loaded"; return s; }

            uint status = fnInitialize();
            if (status != 0u) { s.Error = StatusText("Initialize", status); return s; }

            IntPtr handle;
            status = fnCreateSession(out handle);
            if (status != 0u) { s.Error = StatusText("CreateSession", status); return s; }
            s.Handle = handle;

            status = fnLoadSettings(handle);
            if (status != 0u) { s.Error = StatusText("LoadSettings", status); s.Close(); return s; }

            IntPtr profile;
            status = fnFindProfile(handle, ProfileName, out profile);
            if (status != 0u) { s.Error = StatusText("FindProfileByName", status); s.Close(); return s; }
            if (profile == IntPtr.Zero) { s.Error = "profile not found: " + ProfileName; s.Close(); return s; }
            s.Profile = profile;
        }
        catch (Exception ex)
        {
            s.Error = "session failed: " + ex.Message;
            s.Close();
        }
        return s;
    }

    // Initialize -> CreateSession -> LoadSettings -> GetBaseProfile.
    // W-NV2: the Base profile is not addressable by name, so it needs its own open path.
    public static PcbNvSession OpenBase()
    {
        PcbNvSession s = new PcbNvSession();
        try
        {
            if (fnInitialize == null) { s.Error = loadError != null ? loadError : "nvapi not loaded"; return s; }

            uint status = fnInitialize();
            if (status != 0u) { s.Error = StatusText("Initialize", status); return s; }

            IntPtr handle;
            status = fnCreateSession(out handle);
            if (status != 0u) { s.Error = StatusText("CreateSession", status); return s; }
            s.Handle = handle;

            status = fnLoadSettings(handle);
            if (status != 0u) { s.Error = StatusText("LoadSettings", status); s.Close(); return s; }

            if (fnGetBaseProfile == null) { s.Error = "GetBaseProfile not bound"; s.Close(); return s; }

            IntPtr profile;
            status = fnGetBaseProfile(handle, out profile);
            if (status != 0u) { s.Error = StatusText("GetBaseProfile", status); s.Close(); return s; }
            if (profile == IntPtr.Zero) { s.Error = "base profile not found"; s.Close(); return s; }
            s.Profile = profile;
        }
        catch (Exception ex)
        {
            s.Error = "base session failed: " + ex.Message;
            s.Close();
        }
        return s;
    }

    // A setting that is not present in the profile reports NVAPI_SETTING_NOT_FOUND,
    // which is a valid answer: value 0, not user set, no error.
    public static PcbNvReadResult Read(PcbNvSession s, uint id)
    {
        PcbNvReadResult r = new PcbNvReadResult();
        r.Value = 0u;
        r.UserSet = false;
        r.Name = "";
        if (s == null || !s.Ok) { r.Error = (s != null && s.Error != null) ? s.Error : "no session"; return r; }

        IntPtr buffer = IntPtr.Zero;
        try
        {
            buffer = Marshal.AllocHGlobal(SettingSize);
            Zero(buffer);
            Marshal.WriteInt32(buffer, OffVersion, unchecked((int)(SettingSize | (1 << 16))));
            Marshal.WriteInt32(buffer, OffSettingId, unchecked((int)id));

            uint status = fnGetSetting(s.Handle, s.Profile, id, buffer);
            r.Status = status;
            if (status == StatusNotFound) { return r; }
            if (status != 0u) { r.Error = StatusText("GetSetting", status); return r; }

            r.Value = (uint)Marshal.ReadInt32(buffer, OffCurrentValue);
            uint location = (uint)Marshal.ReadInt32(buffer, OffLocation);
            uint currentPredefined = (uint)Marshal.ReadInt32(buffer, OffIsCurrentPredefined);
            r.UserSet = (location == 0u && currentPredefined == 0u);

            string name = Marshal.PtrToStringUni(new IntPtr(buffer.ToInt64() + OffName));
            if (name != null) { r.Name = name; }
        }
        catch (Exception ex)
        {
            r.Error = "read failed: " + ex.Message;
        }
        finally
        {
            if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); }
        }
        return r;
    }

    public static string Write(PcbNvSession s, uint id, uint value)
    {
        if (s == null || !s.Ok) { return (s != null && s.Error != null) ? s.Error : "no session"; }

        IntPtr buffer = IntPtr.Zero;
        try
        {
            buffer = Marshal.AllocHGlobal(SettingSize);
            Zero(buffer);
            Marshal.WriteInt32(buffer, OffVersion, unchecked((int)(SettingSize | (1 << 16))));
            Marshal.WriteInt32(buffer, OffSettingId, unchecked((int)id));
            Marshal.WriteInt32(buffer, OffLocation, 0);
            Marshal.WriteInt32(buffer, OffIsCurrentPredefined, 0);
            Marshal.WriteInt32(buffer, OffIsPredefinedValid, 0);
            Marshal.WriteInt32(buffer, OffPredefinedValue, 0);
            Marshal.WriteInt32(buffer, OffCurrentValue, unchecked((int)value));

            uint status = fnSetSetting(s.Handle, s.Profile, buffer);
            if (status != 0u) { return StatusText("SetSetting", status); }
            return null;
        }
        catch (Exception ex)
        {
            return "set failed: " + ex.Message;
        }
        finally
        {
            if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); }
        }
    }

    // Removing an override that is not there is not a failure: the setting is already
    // at the driver default, which is exactly the requested end state.
    public static string Remove(PcbNvSession s, uint id)
    {
        if (s == null || !s.Ok) { return (s != null && s.Error != null) ? s.Error : "no session"; }
        try
        {
            uint status = fnDeleteSetting(s.Handle, s.Profile, id);
            if (status == 0u || status == StatusNotFound) { return null; }
            return StatusText("DeleteProfileSetting", status);
        }
        catch (Exception ex)
        {
            return "delete failed: " + ex.Message;
        }
    }

    public static string Save(PcbNvSession s)
    {
        if (s == null || !s.Ok) { return (s != null && s.Error != null) ? s.Error : "no session"; }
        try
        {
            uint status = fnSaveSettings(s.Handle);
            if (status != 0u) { return StatusText("SaveSettings", status); }
            return null;
        }
        catch (Exception ex)
        {
            return "save failed: " + ex.Message;
        }
    }
}
'@

function PcbNv-EnsureType {
    if ('PcbNvApi' -as [type]) { return '' }
    try {
        Add-Type -TypeDefinition $script:PcbNvCs -ErrorAction Stop | Out-Null
        return ''
    } catch {
        return ('Add-Type failed: ' + $_.Exception.Message)
    }
}

# Returns '' when the DRS entry points are usable, otherwise the reason.
function PcbNv-Load {
    param([string]$DllName = $script:PcbNvDllDefault)

    $typeError = PcbNv-EnsureType
    if ($typeError) { return $typeError }

    try {
        $result = [PcbNvApi]::EnsureLoaded($DllName)
    } catch {
        return ('nvapi load failed: ' + $_.Exception.Message)
    }
    if ($null -eq $result) { return '' }
    return [string]$result
}

function PcbNv-NewState {
    param(
        [bool]$Available,
        [string]$Profile,
        [string]$ErrorMessage,
        $Settings
    )

    $rows = New-Object System.Collections.ArrayList
    foreach ($spec in $script:PcbNvLolSettings) {
        $value = [uint32]0
        $userSet = [bool]$false
        $name = [string]$spec.Name

        foreach ($entry in @($Settings)) {
            if ($null -eq $entry) { continue }
            if ($null -eq $entry.Id) { continue }
            if ([uint32]$entry.Id -ne [uint32]$spec.Id) { continue }
            $value = [uint32]$entry.Value
            if ($entry.UserSet) { $userSet = [bool]$true }
            if ($entry.Name) { $name = [string]$entry.Name }
            break
        }

        $null = $rows.Add([pscustomobject]@{
            Id      = [uint32]$spec.Id
            Name    = [string]$name
            Value   = [uint32]$value
            UserSet = [bool]$userSet
        })
    }

    return [pscustomobject]@{
        Available = [bool]$Available
        Profile   = [string]$Profile
        Error     = [string]$ErrorMessage
        Settings  = @($rows.ToArray())
    }
}

# Finds one setting row in a state object, live or rehydrated from JSON. $null when absent.
function PcbNv-FindSetting {
    param($State, $Id)

    if ($null -eq $State) { return $null }
    if ($null -eq $State.Settings) { return $null }
    foreach ($entry in @($State.Settings)) {
        if ($null -eq $entry) { continue }
        if ($null -eq $entry.Id) { continue }
        if ([uint32]$entry.Id -eq [uint32]$Id) { return $entry }
    }
    return $null
}

function PcbNv-ReadState {
    param([string]$DllName = $script:PcbNvDllDefault)

    $loadError = PcbNv-Load -DllName $DllName
    if ($loadError) {
        return (PcbNv-NewState -Available $false -Profile $script:PcbNvProfileName -ErrorMessage $loadError)
    }

    $session = $null
    $rows = New-Object System.Collections.ArrayList
    $readError = ''
    $profileMissing = ''

    try {
        $session = [PcbNvApi]::Open()
        if (-not $session.Ok) {
            $profileMissing = [string]$session.Error
        } else {
            foreach ($spec in $script:PcbNvLolSettings) {
                $result = [PcbNvApi]::Read($session, [uint32]$spec.Id)
                if ($result.Error -and -not $readError) { $readError = [string]$result.Error }
                $null = $rows.Add([pscustomobject]@{
                    Id      = [uint32]$spec.Id
                    Name    = [string]$result.Name
                    Value   = [uint32]$result.Value
                    UserSet = [bool]$result.UserSet
                })
            }
        }
    } catch {
        $readError = 'read failed: ' + $_.Exception.Message
    } finally {
        if ($null -ne $session) { $session.Close() }
    }

    if ($profileMissing) {
        return (PcbNv-NewState -Available $false -Profile $script:PcbNvProfileName -ErrorMessage $profileMissing)
    }
    return (PcbNv-NewState -Available $true -Profile $script:PcbNvProfileName -ErrorMessage $readError -Settings @($rows.ToArray()))
}

# Applies a list of {Mode='Set'|'Delete'; Id; Value} actions in one session, then saves once.
# Returns '' on success, otherwise the error text.
function PcbNv-Apply {
    param(
        [string]$DllName = $script:PcbNvDllDefault,
        $Actions
    )

    $loadError = PcbNv-Load -DllName $DllName
    if ($loadError) { return $loadError }

    $session = $null
    $result = ''
    try {
        $session = [PcbNvApi]::Open()
        if (-not $session.Ok) {
            $result = [string]$session.Error
        } else {
            foreach ($action in @($Actions)) {
                if ($null -eq $action) { continue }
                if ([string]$action.Mode -eq 'Delete') {
                    $step = [PcbNvApi]::Remove($session, [uint32]$action.Id)
                } else {
                    $step = [PcbNvApi]::Write($session, [uint32]$action.Id, [uint32]$action.Value)
                }
                if ($step) { $result = [string]$step; break }
            }
            if (-not $result) {
                $saved = [PcbNvApi]::Save($session)
                if ($saved) { $result = [string]$saved }
            }
        }
    } catch {
        $result = 'apply failed: ' + $_.Exception.Message
    } finally {
        if ($null -ne $session) { $session.Close() }
    }
    return [string]$result
}

# Reads the Base profile rows for the given ids. Base is not addressable by name, so this
# uses the GetBaseProfile path. Returns one {Id,Name,Value,UserSet} row per id, or throws-free
# error text via the Error property.
function PcbNv-ReadBaseSettings {
    param(
        [string]$DllName = $script:PcbNvDllDefault,
        [uint32[]]$Ids = @()
    )

    $loadError = PcbNv-Load -DllName $DllName
    if ($loadError) { return [pscustomobject]@{ Ok = [bool]$false; Error = [string]$loadError; Rows = @() } }

    $session = $null
    $rows = New-Object System.Collections.ArrayList
    $readError = ''
    try {
        $session = [PcbNvApi]::OpenBase()
        if (-not $session.Ok) {
            $readError = [string]$session.Error
        } else {
            foreach ($id in $Ids) {
                $result = [PcbNvApi]::Read($session, [uint32]$id)
                if ($result.Error -and -not $readError) { $readError = [string]$result.Error }
                $null = $rows.Add([pscustomobject]@{
                    Id      = [uint32]$id
                    Name    = [string]$result.Name
                    Value   = [uint32]$result.Value
                    UserSet = [bool]$result.UserSet
                })
            }
        }
    } catch {
        $readError = 'base read failed: ' + $_.Exception.Message
    } finally {
        if ($null -ne $session) { $session.Close() }
    }

    return [pscustomobject]@{
        Ok    = [bool](-not $readError)
        Error = [string]$readError
        Rows  = @($rows.ToArray())
    }
}

# Applies Set/Delete actions to the Base profile in one session, then saves once.
# Same action shape as PcbNv-Apply.
function PcbNv-ApplyBase {
    param(
        [string]$DllName = $script:PcbNvDllDefault,
        $Actions
    )

    $loadError = PcbNv-Load -DllName $DllName
    if ($loadError) { return $loadError }

    $session = $null
    $result = ''
    try {
        $session = [PcbNvApi]::OpenBase()
        if (-not $session.Ok) {
            $result = [string]$session.Error
        } else {
            foreach ($action in @($Actions)) {
                if ($null -eq $action) { continue }
                if ([string]$action.Mode -eq 'Delete') {
                    $step = [PcbNvApi]::Remove($session, [uint32]$action.Id)
                } else {
                    $step = [PcbNvApi]::Write($session, [uint32]$action.Id, [uint32]$action.Value)
                }
                if ($step) { $result = [string]$step; break }
            }
            if (-not $result) {
                $saved = [PcbNvApi]::Save($session)
                if ($saved) { $result = [string]$saved }
            }
        }
    } catch {
        $result = 'base apply failed: ' + $_.Exception.Message
    } finally {
        if ($null -ne $session) { $session.Close() }
    }
    return [string]$result
}

function PcbNv-DescribeState {
    param($State)

    if ($null -eq $State) { return 'state=<null>' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($spec in $script:PcbNvLolSettings) {
        $entry = PcbNv-FindSetting -State $State -Id $spec.Id
        if ($null -eq $entry) {
            $null = $parts.Add(('{0}=<missing>' -f $spec.Symbol))
        } else {
            $null = $parts.Add(('{0}={1}/UserSet={2}' -f $spec.Symbol, [uint32]$entry.Value, ([bool]$entry.UserSet)))
        }
    }
    return ('Available={0} Error="{1}" {2}' -f ([bool]$State.Available), [string]$State.Error, ($parts -join ' '))
}

function Get-PcbNvLolState {
    param([string]$DllName = $script:PcbNvDllDefault)

    try {
        return (PcbNv-ReadState -DllName $DllName)
    } catch {
        return (PcbNv-NewState -Available $false -Profile $script:PcbNvProfileName -ErrorMessage ('unexpected: ' + $_.Exception.Message))
    }
}

function Set-PcbNvLol {
    param([string]$DllName = $script:PcbNvDllDefault)

    $before = PcbNv-ReadState -DllName $DllName
    if (-not $before.Available) {
        return [pscustomobject]@{ Ok = [bool]$false; Before = $before; After = $before; Error = [string]$before.Error }
    }

    $actions = New-Object System.Collections.ArrayList
    foreach ($spec in $script:PcbNvLolSettings) {
        $null = $actions.Add(@{ Mode = 'Set'; Id = [uint32]$spec.Id; Value = [uint32]$spec.Target })
    }

    $errorText = PcbNv-Apply -DllName $DllName -Actions @($actions.ToArray())
    $after = PcbNv-ReadState -DllName $DllName

    $ok = [bool]$false
    if (-not $errorText -and $after.Available) {
        $ok = [bool]$true
        foreach ($spec in $script:PcbNvLolSettings) {
            $entry = PcbNv-FindSetting -State $after -Id $spec.Id
            if ($null -eq $entry) { $ok = [bool]$false; break }
            if ([uint32]$entry.Value -ne [uint32]$spec.Target) { $ok = [bool]$false; break }
        }
    }
    if (-not $ok -and -not $errorText) { $errorText = 'verify failed' }

    return [pscustomobject]@{
        Ok     = [bool]$ok
        Before = $before
        After  = $after
        Error  = [string]$errorText
    }
}

function Restore-PcbNvLol {
    param(
        $Before,
        [string]$DllName = $script:PcbNvDllDefault
    )

    if ($null -eq $Before) {
        $state = PcbNv-ReadState -DllName $DllName
        return [pscustomobject]@{ Ok = [bool]$false; After = $state; Error = [string]'Before state missing' }
    }

    $actions = New-Object System.Collections.ArrayList
    foreach ($spec in $script:PcbNvLolSettings) {
        $entry = PcbNv-FindSetting -State $Before -Id $spec.Id
        if ($null -ne $entry -and $entry.UserSet) {
            $null = $actions.Add(@{ Mode = 'Set'; Id = [uint32]$spec.Id; Value = [uint32]$entry.Value })
        } else {
            $null = $actions.Add(@{ Mode = 'Delete'; Id = [uint32]$spec.Id })
        }
    }

    $errorText = PcbNv-Apply -DllName $DllName -Actions @($actions.ToArray())
    $after = PcbNv-ReadState -DllName $DllName

    $ok = [bool]$false
    if (-not $errorText -and $after.Available) { $ok = [bool]$true }
    if (-not $ok -and -not $errorText) { $errorText = 'restore failed' }

    return [pscustomobject]@{
        Ok    = [bool]$ok
        After = $after
        Error = [string]$errorText
    }
}

# ==== end nvidia.ps1 ====

# ==== begin irq.ps1 ====
# src\irq.ps1 - live IRQ-affinity pinning for the PC-bang kit (W-PCB3).
# Dot-sourced by W-PCB1's main script. ASCII only, stock Windows PowerShell 5.1, elevated.
#
# Public functions:
#   Get-PcbIrqTargets
#     -> @([pscustomobject]@{ Role='mouse-xhci'|'kbd-xhci'|'gpu'|'nic'; InstanceId; Name })
#   Set-PcbIrqPins -IrqMask <uint64> [-Targets <list>] [-NoRestart] [-DryRun]
#     -> [pscustomobject]@{ Ok=[bool]; Before=@(<per target record>);
#                           Rows=@([pscustomobject]@{ Step;Item;Before;After;Status }); Error=[string] }
#   Restore-PcbIrqPins -Before <records> [-NoRestart]
#     -> same shape, Before empty
#
# Per-target record: @{ Role; InstanceId; KeyExisted=[bool]; DevicePolicy=<int|$null>; Override=<int[]|$null> }
#
# Where the pin lives:
#   HKLM\SYSTEM\CurrentControlSet\Enum\<InstanceId>\Device Parameters\Interrupt Management\Affinity Policy
#     DevicePolicy          DWORD  4
#     AssignmentSetOverride BINARY 8 bytes little-endian of ([uint64]1 -shl cpu)
# A written pin reaches the running kernel only when the device is restarted
# (pnputil /restart-device for xHCI/GPU, Restart-NetAdapter for a NIC). No reboot needed.
#
# Older Windows 10 builds have no 'pnputil /restart-device'. When pnputil exits with
# anything other than 0 (0 = done, 3010 = reboot required) the xHCI/GPU path falls back to
# Disable-PnpDevice + Enable-PnpDevice, then the same Status polling / enable retries.
# The restart row Status names the path that ran: 'OK' or 'OK (fallback disable/enable)'.
# $script:PcbIrqForceFallback = $true forces the fallback without calling pnputil at all
# (tests only).
#
# Never throws: every failure is reported as a row with Status 'FAIL: <msg>'.

$script:PcbIrqTail = 'Device Parameters\Interrupt Management\Affinity Policy'
$script:PcbIrqEnableAttempts = 3
$script:PcbIrqPollSeconds = 20
$script:PcbIrqForceFallback = $false
$script:PcbIrqAdapterSource = $null
# Tests only: a fake list of input devices (objects with Class, InstanceId, PciAncestor)
# so the parent walk and the restart never touch this PC. $null = live Get-PnpDevice.
$script:PcbIrqInputSource = $null
# Tests only: a fake display-device list (objects with InstanceId + FriendlyName).
$script:PcbIrqDisplaySource = $null
# Tests only: OS build for Get-PcbIrqRestartMethod. $null = this machine's real build.
$script:PcbIrqOsBuild = $null
# pnputil /restart-device first shipped in Windows 10 2004 (build 19041).
$script:PcbIrqPnpUtilMinBuild = 19041

# Registry roots. Every path below is built from these two strings, so a unit test
# can point them at HKCU and exercise the whole apply/restore path without writing
# anywhere under the real Enum or Class tree. The kit itself keeps the HKLM roots.
$script:PcbIrqEnumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum'
$script:PcbIrqClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class'
# Tests only: scriptblocks that replace the live restart / the status poll, so a
# test can run a full apply, a rollback and a restore without touching a device.
# $null = the real Restart-PcbIrqDevice / Wait-PcbIrqDeviceOk.
$script:PcbIrqRestartImpl = $null
$script:PcbIrqPollImpl = $null
# Tests only: hashtable InstanceId -> DEVPKEY_Device_Driver ('{guid}\0000'), the
# class-key subkey of a device. $null = ask the live PnP property store.
$script:PcbIrqDriverMap = $null
# Tests only: hastable InstanceId -> DEVPKEY_Device_Parent. $null = live property store.
$script:PcbIrqParentMap = $null
# Tests only: fake USB child list (objects with InstanceId + Parent) for the root
# hub lookup. $null = walk the live USB-class devices.
$script:PcbIrqUsbChildSource = $null
# Tests only: InstanceId -> the interrupt numbers the device currently owns
# (an array of numbers). $null = ask Win32_PnPAllocatedResource / Win32_IRQResource.
# Used after a restart to say whether the device is on MSI or on line interrupts.
$script:PcbIrqIrqSource = $null

# Home tweak values (latencyfix\irq-apply.ps1:25, p56.ps1:11, usbpower.ps1:25-27,
# b38.ps1:8-11, nv-extreme.ps1:6-15, nv-final.ps1:34). All DWORD except where noted.
$script:PcbIrqDevParamsTail = 'Device Parameters'
$script:PcbIrqMsiTail = 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
# IRQ_PRIORITY is Undefined 0 / Low 1 / Normal 2 / High 3 - there is no member 4,
# so mouse and keyboard get 3 (the value home's 4 would have to mean) and the rest
# keep home's value.
$script:PcbIrqDevicePriority = @{
    'mouse-xhci' = 3
    'kbd-xhci'   = 3
    'gpu'        = 3
    'nic'        = 2
}
# p56.ps1:16 on the xHCI controller itself.
$script:PcbIrqUsbControllerValues = @(
    @{ Name = 'UsbLinkPowerManagement'; Value = 0 },
    @{ Name = 'AllowIdleIrpInD3'; Value = 0 }
)
# usbpower.ps1:25-27 on the USB device that owns the input report.
$script:PcbIrqUsbDeviceValues = @(
    @{ Name = 'EnhancedPowerManagementEnabled'; Value = 0 },
    @{ Name = 'AllowIdleIrpInD3'; Value = 0 },
    @{ Name = 'SelectiveSuspendEnabled'; Value = 0 }
)
# nv-extreme.ps1:6-15 supersedes b38.ps1, nv-final.ps1:34 adds DisableWriteCombining.
$script:PcbIrqNvClassValues = @(
    @{ Name = 'PerfLevelSrc'; Value = 0x2222 },
    @{ Name = 'EnableDynamicPstate'; Value = 0 },
    @{ Name = 'DisableDynamicPstate'; Value = 1 },
    @{ Name = 'PowerMizerEnable'; Value = 1 },
    @{ Name = 'PowerMizerLevel'; Value = 1 },
    @{ Name = 'PowerMizerLevelAC'; Value = 1 },
    @{ Name = 'RMHdcpKeyglobZero'; Value = 1 },
    @{ Name = 'DisableVideoPort'; Value = 0 },
    @{ Name = 'DisableWriteCombining'; Value = 0 }
)
$script:PcbIrqNvVendor = 'PCI\VEN_10DE'

function Write-PcbIrqOut {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function New-PcbIrqRow {
    param([string]$Step, [string]$Item, [string]$Before, [string]$After, [string]$Status, [string]$Detail = '')
    return [pscustomobject]@{
        Step   = $Step
        Item   = $Item
        Before = $Before
        After  = $After
        Status = $Status
        Detail = $Detail
    }
}

function Get-PcbIrqIrqNumbers {
    # The interrupt numbers one device owns right now. A message-signaled vector is
    # reported by WMI as an IRQ number above 0x7FFFFFFF (a negative int32); a classic
    # line interrupt is a small positive number. $script:PcbIrqIrqSource lets a unit
    # test inject the list (a scriptblock taking the InstanceId, returning numbers).
    param([string]$InstanceId)
    $out = @()
    if ($script:PcbIrqIrqSource -ne $null) {
        try {
            foreach ($v in @(& $script:PcbIrqIrqSource $InstanceId)) {
                if ($v -eq $null) { continue }
                $out += [uint64]$v
            }
        } catch { }
        return $out
    }
    try {
        $wql = "DeviceID='" + ($InstanceId -replace '\\', '\\') + "'"
        $ent = Get-CimInstance -ClassName Win32_PnPEntity -Filter $wql -ErrorAction Stop
        if ($ent -ne $null) {
            $res = @(Get-CimAssociatedInstance -InputObject $ent -Association Win32_PnPAllocatedResource -ResultClassName Win32_IRQResource -ErrorAction SilentlyContinue)
            foreach ($r in $res) {
                if ($r -eq $null -or $r.IRQNumber -eq $null) { continue }
                $out += [uint64]$r.IRQNumber
            }
        }
    } catch { }
    return $out
}

function Get-PcbIrqInterruptType {
    # 'msi=yes' when at least one vector is a message-signaled one. The restart that
    # wrote MSISupported is what decides this, so it is read after the restart.
    param([string]$InstanceId)
    $nums = @(Get-PcbIrqIrqNumbers $InstanceId)
    $msi = 0
    $line = 0
    foreach ($n in $nums) {
        if ([uint64]$n -gt [uint64]0x7FFFFFFF) { $msi = $msi + 1 } else { $line = $line + 1 }
    }
    if ($nums.Count -eq 0) {
        return [pscustomobject]@{ Msi = $false; MsiCount = 0; LineCount = 0; Count = 0; Text = 'msi=? (no interrupt resource readable)' }
    }
    $on = 'no'
    if ($msi -gt 0) { $on = 'yes' }
    return [pscustomobject]@{
        Msi      = ($msi -gt 0)
        MsiCount = $msi
        LineCount = $line
        Count    = $nums.Count
        Text     = 'msi=' + $on + ' (' + $msi + ' msi / ' + $line + ' line vector(s))'
    }
}

function Get-PcbIrqEnumKey {
    param([string]$InstanceId)
    return ($script:PcbIrqEnumRoot + '\' + $InstanceId)
}

function Get-PcbIrqApKey {
    param([string]$InstanceId)
    return ((Get-PcbIrqEnumKey $InstanceId) + '\' + $script:PcbIrqTail)
}

function Get-PcbIrqMsiKey {
    param([string]$InstanceId)
    return ((Get-PcbIrqEnumKey $InstanceId) + '\' + $script:PcbIrqMsiTail)
}

function Get-PcbIrqDeviceParent {
    param([string]$InstanceId)
    if ($script:PcbIrqParentMap -ne $null) {
        $k = [string]$InstanceId
        if ($script:PcbIrqParentMap.ContainsKey($k)) { return [string]$script:PcbIrqParentMap[$k] }
        return ''
    }
    try {
        $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
        if ($prop -ne $null -and $prop.Data -ne $null) { return [string]$prop.Data }
    } catch { }
    return ''
}

function Get-PcbIrqDriverSubkey {
    # The class-key instance of a device: '{4d36e968-...}\0000' from DEVPKEY_Device_Driver.
    # Not always \0000, so it is always asked for. $script:PcbIrqDriverMap lets a test
    # inject the mapping; $null = the live property store.
    param([string]$InstanceId)
    if ($script:PcbIrqDriverMap -ne $null) {
        $k = [string]$InstanceId
        if ($script:PcbIrqDriverMap.ContainsKey($k)) { return [string]$script:PcbIrqDriverMap[$k] }
        return ''
    }
    try {
        $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction SilentlyContinue
        if ($prop -ne $null -and $prop.Data -ne $null) { return [string]$prop.Data }
    } catch { }
    return ''
}

function Get-PcbIrqUsbAncestors {
    # Every USB\* ancestor of a HID device: the interface node (USB\VID_x&PID_y&MI_nn)
    # and the composite device under it. Home wrote its USB power values to both.
    param([string]$InstanceId)
    $out = New-Object System.Collections.ArrayList
    $cur = $InstanceId
    for ($hop = 0; $hop -lt 16; $hop++) {
        $cur = Get-PcbIrqDeviceParent $cur
        if ([string]::IsNullOrWhiteSpace($cur)) { break }
        if ($cur -like 'PCI\*') { break }
        if ($cur -like 'USB\*') {
            $hit = $false
            foreach ($x in $out) { if ([string]$x -eq $cur) { $hit = $true } }
            if (-not $hit) { [void]$out.Add($cur) }
        }
    }
    return $out
}

function Get-PcbIrqUsbChildren {
    # USB-class devices whose parent is this controller: the USB\ROOT_HUB* node.
    param([string]$InstanceId)
    $out = New-Object System.Collections.ArrayList
    if ($script:PcbIrqUsbChildSource -ne $null) {
        foreach ($d in @($script:PcbIrqUsbChildSource)) {
            if ($null -eq $d) { continue }
            if ([string]$d.Parent -ne $InstanceId) { continue }
            [void]$out.Add([string]$d.InstanceId)
        }
        return $out
    }
    try {
        foreach ($d in @(Get-PnpDevice -Class USB -PresentOnly -ErrorAction SilentlyContinue)) {
            if ($null -eq $d) { continue }
            if ((Get-PcbIrqDeviceParent ([string]$d.InstanceId)) -ne $InstanceId) { continue }
            [void]$out.Add([string]$d.InstanceId)
        }
    } catch { }
    return $out
}

function Get-PcbIrqExtraPlan {
    # Everything Set-PcbIrqPins writes besides the pin, in write order, as
    # @{ Path; Name; Value; Kind }. Paths are absolute and built from the two roots.
    param([string]$Role, [string]$InstanceId)
    $plan = New-Object System.Collections.ArrayList
    $enumKey = Get-PcbIrqEnumKey $InstanceId

    # 1. MSI on every pinned device (home: GPU, NIC, both xHCI).
    [void]$plan.Add(@{ Path = ($enumKey + '\' + $script:PcbIrqMsiTail); Name = 'MSISupported'; Value = 1; Kind = 'DWord' })

    # 2. DevicePriority next to the affinity pin. 4 is not an IRQ_PRIORITY member.
    $prio = $null
    if ($script:PcbIrqDevicePriority.ContainsKey($Role)) { $prio = $script:PcbIrqDevicePriority[$Role] }
    if ($prio -ne $null) {
        $apKey = Get-PcbIrqApKey $InstanceId
        [void]$plan.Add(@{ Path = $apKey; Name = 'DevicePriority'; Value = [int]$prio; Kind = 'DWord' })
    }

    # 3. USB power: the controller's link-power value, then the root hub and every
    #    USB node that owns an input device of this controller. The children
    #    re-enumerate with the controller restart, so they pick the values up.
    if ($Role -eq 'mouse-xhci' -or $Role -eq 'kbd-xhci') {
        $dpKey = $enumKey + '\' + $script:PcbIrqDevParamsTail
        foreach ($v in $script:PcbIrqUsbControllerValues) {
            [void]$plan.Add(@{ Path = $dpKey; Name = $v.Name; Value = [int]$v.Value; Kind = 'DWord' })
        }
        $usbIds = New-Object System.Collections.ArrayList
        foreach ($hub in @(Get-PcbIrqUsbChildren $InstanceId)) { [void]$usbIds.Add([string]$hub) }
        foreach ($cls in @('Mouse','Keyboard')) {
            foreach ($d in @(Get-PcbIrqInputDevices -Class $cls)) {
                if ($null -eq $d) { continue }
                $iid = [string]$d.InstanceId
                if ([string]::IsNullOrWhiteSpace($iid)) { continue }
                $anc = $null
                if ($script:PcbIrqInputSource -ne $null) { $anc = [string]$d.PciAncestor } else { $anc = Get-PcbIrqPciAncestor -InstanceId $iid }
                if ($anc -ne $InstanceId) { continue }
                foreach ($u in @(Get-PcbIrqUsbAncestors $iid)) {
                    $hit = $false
                    foreach ($x in $usbIds) { if ([string]$x -eq [string]$u) { $hit = $true } }
                    if (-not $hit) { [void]$usbIds.Add([string]$u) }
                }
            }
        }
        foreach ($u in $usbIds) {
            $p = $script:PcbIrqEnumRoot + '\' + $u + '\' + $script:PcbIrqDevParamsTail
            foreach ($v in $script:PcbIrqUsbDeviceValues) {
                [void]$plan.Add(@{ Path = $p; Name = $v.Name; Value = [int]$v.Value; Kind = 'DWord' })
            }
        }
    }

    # 4. NVIDIA class key. Only for a GeForce card - no other vendor gets these.
    if ($Role -eq 'gpu' -and $InstanceId -like ($script:PcbIrqNvVendor + '*')) {
        $sub = Get-PcbIrqDriverSubkey $InstanceId
        if (-not [string]::IsNullOrWhiteSpace($sub)) {
            $clsKey = $script:PcbIrqClassRoot + '\' + $sub
            foreach ($v in $script:PcbIrqNvClassValues) {
                [void]$plan.Add(@{ Path = $clsKey; Name = $v.Name; Value = [int]$v.Value; Kind = 'DWord' })
            }
        }
    }

    return $plan
}

function Read-PcbIrqExtraState {
    # @{ Existed; Value; Kind } for one value. Absent -> Existed=$false, Value=$null.
    # Kind is the real registry kind name (DWord / String / Binary / ...), so a value
    # that was already there comes back with its own type, not with ours.
    param([string]$Path, [string]$Name)
    $st = @{ Existed = $false; Value = $null; Kind = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $st }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($raw -eq $null) { return $st }
        $kind = 'DWord'
        try { $kind = [string]$key.GetValueKind($Name) } catch { $kind = 'DWord' }
        $st.Existed = $true
        if ($kind -eq 'Binary') {
            $b = @()
            foreach ($x in @($raw)) { $b += [int]$x }
            $st.Value = $b
        } elseif ($kind -eq 'MultiString') {
            $st.Value = @($raw)
        } else {
            $st.Value = $raw
        }
        $st.Kind = $kind
    } catch { }
    return $st
}

function Write-PcbIrqValue {
    # $Kind 'DWord' / 'String' / 'Binary' / 'QWord' / ...; $null value -> delete the value.
    param([string]$Path, [string]$Name, $Kind, $Value)
    if ($Value -eq $null) {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
    if ($Kind -eq 'Binary') {
        $bytes = [byte[]](@($Value) | ForEach-Object { [byte][int]$_ })
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType Binary -Value $bytes -Force
    } elseif ($Kind -eq 'MultiString') {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType MultiString -Value ([string[]]@($Value)) -Force
    } elseif ($Kind -eq 'QWord') {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType QWord -Value ([uint64]$Value) -Force
    } elseif ($Kind -eq 'String' -or $Kind -eq 'ExpandString') {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value ([string]$Value) -Force
    } else {
        $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value ([int]$Value) -Force
    }
}

function Write-PcbIrqExtraPlan {
    # Writes the plan, returns the record entries (before state per value) plus the
    # list of keys the kit created, so Restore can put everything back.
    param($Plan)
    $entries = New-Object System.Collections.ArrayList
    $created = New-Object System.Collections.ArrayList
    $seenKey = @{}
    foreach ($p in @($Plan)) {
        if ($p -eq $null) { continue }
        $path = [string]$p.Path
        $name = [string]$p.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $keyExisted = Test-Path -LiteralPath $path
        if (-not $keyExisted) {
            # Record every level that does not exist yet, so Restore can remove the
            # whole chain again (deepest first) once it is empty.
            $cur = $path
            while (-not [string]::IsNullOrWhiteSpace($cur)) {
                if ((Test-Path -LiteralPath $cur)) { break }
                if (-not $seenKey.ContainsKey($cur)) {
                    $seenKey[$cur] = $true
                    [void]$created.Add($cur)
                }
                $parent = Split-Path -Parent $cur
                if ([string]::IsNullOrWhiteSpace($parent)) { break }
                if ($parent -eq $script:PcbIrqEnumRoot -or $parent -eq $script:PcbIrqClassRoot) { break }
                if ($parent -eq 'HKCU:\Software' -or $parent -eq 'HKCU:' -or $parent -eq 'HKLM:\SYSTEM') { break }
                $cur = $parent
            }
        }
        $st = Read-PcbIrqExtraState $path $name
        # A value that was already there must come back with its own registry kind,
        # not with the kind the kit wanted to write.
        $kind = [string]$p.Kind
        if ($st.Existed -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$st.Kind)) { $kind = [string]$st.Kind }
        [void]$entries.Add([pscustomobject]@{
                Path   = $path
                Name   = $name
                Kind   = $kind
                Existed = [bool]$st.Existed
                Before = $st.Value
                After  = $p.Value
            })
        Write-PcbIrqValue $path $name ([string]$p.Kind) $p.Value
    }
    return [pscustomobject]@{ Entries = @($entries.ToArray()); CreatedKeys = @($created.ToArray()) }
}

function Test-PcbIrqKeyEmpty {
    # $true when the key exists and holds neither values nor subkeys.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $items = @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) { return $false }
    } catch { return $false }
    $n = 0
    try {
        $props = @(Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue)
        if ($props.Count -gt 0) {
            foreach ($pr in $props[0].PSObject.Properties) { if ($pr.Name -notlike 'PS*') { $n++ } }
        }
    } catch { return $false }
    return ($n -eq 0)
}

function Remove-PcbIrqEmptyKeyChain {
    # Removes $Path and every empty ancestor above it, so a key the kit created for
    # this device disappears completely. Stops at the two injected roots and at the
    # first ancestor that still holds something.
    param([string]$Path)
    $cur = $Path
    for ($hop = 0; $hop -lt 16; $hop++) {
        if ([string]::IsNullOrWhiteSpace($cur)) { break }
        $stop = $false
        foreach ($r in @([string]$script:PcbIrqEnumRoot, [string]$script:PcbIrqClassRoot)) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            if ($cur.Length -le $r.Length) { $stop = $true }
        }
        if ($stop) { break }
        if (-not (Test-Path -LiteralPath $cur)) { break }
        if (-not (Test-PcbIrqKeyEmpty $cur)) { break }
        try { Remove-Item -LiteralPath $cur -Force -ErrorAction Stop } catch { break }
        $cur = Split-Path -Parent $cur
    }
}

function Restore-PcbIrqExtras {
    # Writes every recorded before state back: a value that was absent is deleted, a
    # pre-seeded value comes back with its value. Keys the kit created are removed
    # again when they end up empty.
    param($Entries, $CreatedKeys)
    $bad = New-Object System.Collections.ArrayList
    foreach ($e in @($Entries)) {
        if ($e -eq $null) { continue }
        try {
            if ($e.Existed -eq $true) {
                Write-PcbIrqValue ([string]$e.Path) ([string]$e.Name) ([string]$e.Kind) $e.Before
            } else {
                Write-PcbIrqValue ([string]$e.Path) ([string]$e.Name) ([string]$e.Kind) $null
            }
        } catch {
            [void]$bad.Add('restore ' + $e.Name + ': ' + $_.Exception.Message)
        }
    }
    # Deepest key first, and each removal walks back up its ancestors: one key can hold
    # another key the kit created (Device Parameters -> Interrupt Management -> ...),
    # so an ancestor only becomes empty after its last child is gone.
    $keys = @($CreatedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $keys = @($keys | Sort-Object -Property @{ Expression = { ([string]$_).Length }; Descending = $true })
    foreach ($k in $keys) {
        $k = [string]$k
        try {
            Remove-PcbIrqEmptyKeyChain $k
        } catch {
            [void]$bad.Add('restore key ' + $k + ': ' + $_.Exception.Message)
        }
    }
    return @($bad.ToArray())
}

function Format-PcbIrqExtra {
    # 'Name=<absent>->1' / 'Name=0->1'
    param($Entry)
    $b = '<absent>'
    if ($Entry.Existed -eq $true -and $Entry.Before -ne $null) { $b = '' + $Entry.Before }
    return ([string]$Entry.Name + '=' + $b + '->' + ('' + $Entry.After))
}


function Get-PcbIrqBytes {
    param([int]$Cpu)
    # 8 little-endian bytes of 1<<cpu. -shl on [int] wraps at 32 bits, so force [uint64].
    return [BitConverter]::GetBytes([uint64]([uint64]1 -shl $Cpu))
}

function Format-PcbIrqPin {
    param($DevicePolicy, $Override)
    $dp = 'DP=<missing>'
    if ($DevicePolicy -ne $null) { $dp = 'DP=' + [int]$DevicePolicy }
    $ov = 'OV=<missing>'
    if ($Override -ne $null) {
        $parts = @()
        foreach ($b in @($Override)) { $parts += [int]$b }
        $ov = 'OV=[' + ($parts -join ',') + ']'
    }
    return ($dp + ' ' + $ov)
}

function Read-PcbIrqPin {
    param([string]$InstanceId)
    $rec = [pscustomobject]@{
        Role         = $null
        InstanceId   = $InstanceId
        KeyExisted   = $false
        DevicePolicy = $null
        Override     = $null
    }
    try {
        $path = Get-PcbIrqApKey $InstanceId
        $key = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($key -ne $null) { $rec.KeyExisted = $true }
        $props = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($props -ne $null) {
            $p = $props.PSObject.Properties['DevicePolicy']
            if ($p -ne $null -and $p.Value -ne $null) { $rec.DevicePolicy = [int]$p.Value }
            $o = $props.PSObject.Properties['AssignmentSetOverride']
            if ($o -ne $null -and $o.Value -ne $null) {
                $bytes = @()
                foreach ($b in $o.Value) { $bytes += [int]$b }
                $rec.Override = $bytes
            }
        }
    } catch {
        $rec.KeyExisted = $false
        $rec.DevicePolicy = $null
        $rec.Override = $null
    }
    return $rec
}

function Write-PcbIrqPinValues {
    param([string]$InstanceId, $DevicePolicy, $Override)
    # DevicePolicy $null and Override $null -> remove both values, keep the key.
    $path = Get-PcbIrqApKey $InstanceId
    if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -Path $path -Force }
    if ($DevicePolicy -eq $null) {
        Remove-ItemProperty -LiteralPath $path -Name 'DevicePolicy' -ErrorAction SilentlyContinue
    } else {
        $null = New-ItemProperty -LiteralPath $path -Name 'DevicePolicy' -PropertyType DWord -Value ([int]$DevicePolicy) -Force
    }
    if ($Override -eq $null) {
        Remove-ItemProperty -LiteralPath $path -Name 'AssignmentSetOverride' -ErrorAction SilentlyContinue
    } else {
        $bytes = [byte[]](@($Override) | ForEach-Object { [byte][int]$_ })
        $null = New-ItemProperty -LiteralPath $path -Name 'AssignmentSetOverride' -PropertyType Binary -Value $bytes -Force
    }
    return (Format-PcbIrqPin (Read-PcbIrqPin $InstanceId).DevicePolicy (Read-PcbIrqPin $InstanceId).Override)
}

function Get-PcbIrqCpuList {
    param([uint64]$IrqMask)
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 64; $i++) {
        if (([uint64]$IrqMask -band ([uint64]1 -shl $i)) -ne [uint64]0) { [void]$list.Add([int]$i) }
    }
    return $list
}

function Get-PcbIrqCpuForRole {
    # 0 bits -> $null (everything skipped); 1 bit -> b0 for every role;
    # 2+ bits -> mouse-xhci on b1, gpu and nic on b0.
    param([uint64]$IrqMask, [string]$Role)
    $cpus = Get-PcbIrqCpuList $IrqMask
    if ($cpus.Count -eq 0) { return $null }
    if ($cpus.Count -eq 1) { return [int]$cpus[0] }
    if ($Role -eq 'mouse-xhci' -or $Role -eq 'kbd-xhci') { return [int]$cpus[1] }
    return [int]$cpus[0]
}

function Get-PcbIrqPciAncestor {
    # Walk DEVPKEY_Device_Parent from a device instance id up to the first PCI\*
    # ancestor. Returns $null when the device hangs off no PCI bus (PS/2, Bluetooth).
    param([string]$InstanceId)
    $cur = $InstanceId
    if ([string]::IsNullOrWhiteSpace($cur)) { return $null }
    for ($hop = 0; $hop -lt 16; $hop++) {
        $parent = Get-PcbIrqDeviceParent $cur
        if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
        $cur = $parent
        if ($cur -like 'PCI\*') { return $cur }
    }
    return $null
}

function Get-PcbIrqInputDevices {
    # The input devices that own a PCI controller. $script:PcbIrqInputSource lets a unit
    # test inject a fake list (objects with Class, InstanceId, PciAncestor); $null means
    # the live Get-PnpDevice walk.
    param([string]$Class)
    if ($script:PcbIrqInputSource -ne $null) {
        return @($script:PcbIrqInputSource | Where-Object { $null -ne $_ -and [string]$_.Class -eq $Class })
    }
    try {
        return @(Get-PnpDevice -Class $Class -PresentOnly -ErrorAction SilentlyContinue)
    } catch {
        return @()
    }
}

function Get-PcbIrqTargets {
    $out = New-Object System.Collections.ArrayList
    $seenMouse = @{}
    $injected = ($script:PcbIrqInputSource -ne $null)

    # mouse-xhci / kbd-xhci: for every present Mouse- and Keyboard-class device walk
    # DEVPKEY_Device_Parent up to the first PCI\* ancestor; unique controllers only.
    # Keyboards come second on purpose: a controller that already carries the mouse
    # keeps Role 'mouse-xhci', and a keyboard-only controller is the one that gets
    # 'kbd-xhci', so no controller is ever added twice.
    foreach ($cls in @('Mouse','Keyboard')) {
        $role = 'mouse-xhci'
        if ($cls -eq 'Keyboard') { $role = 'kbd-xhci' }
        try {
            $devs = @(Get-PcbIrqInputDevices -Class $cls)
            foreach ($d in $devs) {
                if ($null -eq $d) { continue }
                $iid = [string]$d.InstanceId
                if ([string]::IsNullOrWhiteSpace($iid)) { continue }
                $found = $null
                if ($injected) { $found = [string]$d.PciAncestor } else { $found = Get-PcbIrqPciAncestor -InstanceId $iid }
                if ([string]::IsNullOrWhiteSpace($found)) { continue }
                $k = $found.ToLowerInvariant()
                if ($seenMouse.ContainsKey($k)) { continue }
                $seenMouse[$k] = $true
                $nm = ''
                if (-not $injected) {
                    try {
                        $ctrl = Get-PnpDevice -InstanceId $found -ErrorAction SilentlyContinue
                        if ($ctrl -ne $null) { $nm = [string]$ctrl.FriendlyName }
                    } catch { $nm = '' }
                }
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = [string]$d.FriendlyName }
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = $found }
                [void]$out.Add([pscustomobject]@{ Role = $role; InstanceId = $found; Name = $nm })
            }
        } catch { }
    }

    # gpu: present Display-class devices whose InstanceId starts with PCI\.  An Intel
    # integrated GPU (PCI\VEN_8086*) is dropped when a discrete one is also present - the
    # iGPU's interrupt is not worth a core slot, and on a desktop it usually drives nothing.
    try {
        if ($script:PcbIrqDisplaySource -ne $null) {
            $disps = @($script:PcbIrqDisplaySource)
        } else {
            $disps = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)
        }
        $gpuList = New-Object System.Collections.ArrayList
        $hasDiscrete = $false
        foreach ($d in $disps) {
            if ($null -eq $d) { continue }
            $id = [string]$d.InstanceId
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($id -notlike 'PCI\*') { continue }
            if ($id -notlike 'PCI\VEN_8086*') { $hasDiscrete = $true }
            [void]$gpuList.Add($d)
        }
        foreach ($d in $gpuList) {
            $id = [string]$d.InstanceId
            if ($hasDiscrete -and $id -like 'PCI\VEN_8086*') {
                Write-PcbIrqOut ('  skip integrated GPU ' + $id + ' (discrete GPU present)')
                continue
            }
            [void]$out.Add([pscustomobject]@{ Role = 'gpu'; InstanceId = $id; Name = [string]$d.FriendlyName })
        }
    } catch { }

    # nic: physical adapters that are Up on 802.3, PCI bus only. A USB Ethernet dongle
    # (PnPDeviceID 'USB\VID_...') has no interrupt line of its own - the USB host
    # controller owns it - so pinning its PCI path (or restarting it) is meaningless.
    # $script:PcbIrqAdapterSource lets a unit test inject a fake adapter list
    # (objects with .PnPDeviceID and .Name); $null means the live Get-NetAdapter.
    try {
        if ($script:PcbIrqAdapterSource -ne $null) {
            $nics = @($script:PcbIrqAdapterSource)
        } else {
            $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
                $_.Status -eq 'Up' -and $_.MediaType -eq '802.3'
            })
        }
        foreach ($n in $nics) {
            $id = [string]$n.PnPDeviceID
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($id -notlike 'PCI\*') { continue }
            [void]$out.Add([pscustomobject]@{ Role = 'nic'; InstanceId = $id; Name = [string]$n.Name })
        }
    } catch { }

    return $out
}

function Get-PcbIrqNetAdapter {
    param([string]$InstanceId)
    try {
        return (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.PnPDeviceID -eq $InstanceId } |
            Select-Object -First 1)
    } catch { return $null }
}

function Wait-PcbIrqDeviceOk {
    param([string]$InstanceId, [int]$TimeoutSec)
    $enables = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 'unknown'
    $lastProblem = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $dev = $null
        try { $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue } catch { $dev = $null }
        if ($dev -ne $null) {
            $lastStatus = [string]$dev.Status
            $lastProblem = [string]$dev.Problem
            if ($lastStatus -eq 'OK') {
                return [pscustomobject]@{ Ok = $true; Status = $lastStatus; Problem = $lastProblem; Enables = $enables }
            }
            $needEnable = ($lastStatus -eq 'Error') -or ($lastProblem -eq 'CM_PROB_DISABLED')
            if ($needEnable -and $enables -lt $script:PcbIrqEnableAttempts) {
                $enables = $enables + 1
                Write-PcbIrqOut ('  ' + $InstanceId + ' -> Status ' + $lastStatus + ' / ' + $lastProblem + ' ; pnputil /enable-device attempt ' + $enables)
                $eo = & pnputil.exe /enable-device "$InstanceId" 2>&1
                Write-PcbIrqOut ('  pnputil /enable-device exit ' + $LASTEXITCODE + ' out: ' + ((@($eo) | ForEach-Object { ('' + $_).Trim() }) -join ' | '))
            }
        }
        Start-Sleep -Seconds 1
    }
    return [pscustomobject]@{ Ok = $false; Status = $lastStatus; Problem = $lastProblem; Enables = $enables }
}

function Restart-PcbIrqByDisableEnable {
    # Fallback for builds without 'pnputil /restart-device'. Same live effect: the driver
    # is torn down and re-started, so a freshly written Affinity Policy is re-read.
    # Returns just the detail suffix; Status/polling stays in Restart-PcbIrqDevice.
    param([string]$InstanceId)
    $detail = ''
    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Write-PcbIrqOut ('  Disable-PnpDevice ' + $InstanceId + ' -> ok')
        $detail = 'disable ok'
    } catch {
        Write-PcbIrqOut ('  Disable-PnpDevice ' + $InstanceId + ' -> ' + $_.Exception.Message)
        $detail = 'disable failed: ' + $_.Exception.Message
    }
    Start-Sleep -Seconds 1
    try {
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Write-PcbIrqOut ('  Enable-PnpDevice ' + $InstanceId + ' -> ok')
        $detail = $detail + ' / enable ok'
    } catch {
        Write-PcbIrqOut ('  Enable-PnpDevice ' + $InstanceId + ' -> ' + $_.Exception.Message)
        $detail = $detail + ' / enable failed: ' + $_.Exception.Message
    }
    return $detail
}

function Get-PcbIrqRestartMethod {
    # 'pnputil /restart-device' first shipped in Windows 10 version 2004 (build 19041).
    # Below that build the verb does not exist and some pnputil versions still exit 0,
    # so the exit-code fallback would never fire.  Choose the method up front instead.
    # $script:PcbIrqOsBuild lets a unit test inject a build number.
    $b = $script:PcbIrqOsBuild
    if ($b -eq $null) {
        try { $b = [int][Environment]::OSVersion.Version.Build } catch { $b = 0 }
    }
    if ([int]$b -lt $script:PcbIrqPnpUtilMinBuild) { return 'disable-enable' }
    return 'pnputil'
}

function Invoke-PcbIrqRestart {
    # Restart-PcbIrqDevice, or the injected stand-in.
    param([string]$Role, [string]$InstanceId)
    if ($script:PcbIrqRestartImpl -ne $null) { return (& $script:PcbIrqRestartImpl $Role $InstanceId) }
    return (Restart-PcbIrqDevice $Role $InstanceId)
}

function Invoke-PcbIrqPoll {
    # Wait-PcbIrqDeviceOk ($InstanceId, $TimeoutSec) -> @{ Ok; Status; Problem; Enables },
    # or the injected stand-in. A stand-in may return a bare $true/$false.
    param([string]$InstanceId, [int]$TimeoutSec)
    if ($script:PcbIrqPollImpl -ne $null) { return (& $script:PcbIrqPollImpl $InstanceId $TimeoutSec) }
    return (Wait-PcbIrqDeviceOk $InstanceId $TimeoutSec)
}

function ConvertTo-PcbIrqPoll {
    # Normalises a poll result of either shape.
    param($Poll)
    if ($Poll -eq $null) { return [pscustomobject]@{ Ok = $false; Status = 'unknown'; Problem = ''; Enables = 0 } }
    if ($Poll -is [bool]) {
        if ($Poll) { return [pscustomobject]@{ Ok = $true; Status = 'OK'; Problem = ''; Enables = 0 } }
        return [pscustomobject]@{ Ok = $false; Status = 'not OK'; Problem = ''; Enables = 0 }
    }
    $ok = $false
    try { $ok = [bool]$Poll.Ok } catch { $ok = $false }
    $st = ''
    try { $st = [string]$Poll.Status } catch { $st = '' }
    $pr = ''
    try { $pr = [string]$Poll.Problem } catch { $pr = '' }
    $en = 0
    try { $en = [int]$Poll.Enables } catch { $en = 0 }
    return [pscustomobject]@{ Ok = $ok; Status = $st; Problem = $pr; Enables = $en }
}

function Format-PcbIrqPollFail {
    param($Poll)
    $msg = 'final Status ' + $Poll.Status
    if (-not [string]::IsNullOrWhiteSpace($Poll.Problem)) { $msg = $msg + ' / ' + $Poll.Problem }
    return $msg
}

function Restart-PcbIrqDevice {
    # Returns @{ Status; Detail }. Status is 'OK', 'OK (fallback disable/enable)' or 'FAIL: <msg>'.
    param([string]$Role, [string]$InstanceId)

    $adapter = Get-PcbIrqNetAdapter $InstanceId
    if ($adapter -ne $null) {
        Write-PcbIrqOut ('network drops for a few seconds on ' + $adapter.Name)
        $name = [string]$adapter.Name
        try {
            Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Status = ('FAIL: Restart-NetAdapter ' + $_.Exception.Message); Detail = $name }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $st = 'unknown'
        while ($sw.Elapsed.TotalSeconds -lt $script:PcbIrqPollSeconds) {
            Start-Sleep -Seconds 1
            $a = $null
            try { $a = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue } catch { $a = $null }
            if ($a -ne $null) { $st = [string]$a.Status }
            if ($st -eq 'Up') { return [pscustomobject]@{ Status = 'OK'; Detail = ($name + ' Up') } }
        }
        return [pscustomobject]@{ Status = ('FAIL: adapter ' + $name + ' final Status ' + $st); Detail = $name }
    }

    if ($Role -eq 'mouse-xhci' -or $Role -eq 'kbd-xhci' -or $Role -eq 'gpu') {
        Write-PcbIrqOut 'input/screen drops for a few seconds'
    }

    $usedFallback = $false
    $fbDetail = ''
    $method = Get-PcbIrqRestartMethod
    if ($script:PcbIrqForceFallback -eq $true) {
        Write-PcbIrqOut '  fallback forced ($script:PcbIrqForceFallback = $true), pnputil /restart-device not called'
        $usedFallback = $true
        $fbDetail = Restart-PcbIrqByDisableEnable $InstanceId
    } elseif ($method -eq 'disable-enable') {
        Write-PcbIrqOut ('  OS build ' + $script:PcbIrqOsBuild + ' has no pnputil /restart-device, using disable/enable')
        $usedFallback = $true
        $fbDetail = Restart-PcbIrqByDisableEnable $InstanceId
    } else {
        $ro = & pnputil.exe /restart-device "$InstanceId" 2>&1
        $code = $LASTEXITCODE
        Write-PcbIrqOut ('  pnputil /restart-device ' + $InstanceId + ' exit ' + $code + ' out: ' + ((@($ro) | ForEach-Object { ('' + $_).Trim() }) -join ' | '))
        if ($code -eq 3010) {
            return [pscustomobject]@{ Status = 'FAIL: reboot required'; Detail = 'exit 3010' }
        }
        if ($code -ne 0) {
            # older Windows 10 builds have no such verb; anything else non-zero is a
            # restart that did not happen. Either way, try disable/enable instead.
            Write-PcbIrqOut ('  pnputil /restart-device unusable (exit ' + $code + '), falling back to disable/enable')
            $usedFallback = $true
            $fbDetail = Restart-PcbIrqByDisableEnable $InstanceId
        }
    }

    $poll = ConvertTo-PcbIrqPoll (Invoke-PcbIrqPoll $InstanceId $script:PcbIrqPollSeconds)
    if ($poll.Ok) {
        $detail = 'Status OK after ' + $poll.Enables + ' enable attempt(s)'
        if ($usedFallback) { $detail = $detail + ' ; fallback: ' + $fbDetail }
        if ($usedFallback) { return [pscustomobject]@{ Status = 'OK (fallback disable/enable)'; Detail = $detail } }
        return [pscustomobject]@{ Status = 'OK'; Detail = $detail }
    }
    $msg = 'final Status ' + $poll.Status
    if (-not [string]::IsNullOrWhiteSpace($poll.Problem)) { $msg = $msg + ' / ' + $poll.Problem }
    return [pscustomobject]@{ Status = ('FAIL: ' + $msg); Detail = $msg }
}

function Set-PcbIrqPins {
    param(
        [uint64]$IrqMask,
        $Targets = $null,
        [switch]$NoRestart,
        [switch]$DryRun
    )

    $rows = New-Object System.Collections.ArrayList
    $before = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    if ($Targets -eq $null) {
        try { $Targets = @(Get-PcbIrqTargets) } catch { $Targets = @() }
    }
    $Targets = @($Targets)

    $ncpu = 1
    try { $ncpu = [int]$env:NUMBER_OF_PROCESSORS } catch { $ncpu = 1 }

    Write-PcbIrqOut ('IrqMask 0x' + ([uint64]$IrqMask).ToString('X') + ' -> cpus [' + ((Get-PcbIrqCpuList $IrqMask) -join ',') + ']')

    foreach ($t in $Targets) {
        $role = [string]$t.Role
        $id = [string]$t.InstanceId
        $item = $role + ' ' + $id

        $rec = $null
        try {
            $rec = Read-PcbIrqPin $id
            $rec.Role = $role
        } catch {
            $rec = [pscustomobject]@{ Role = $role; InstanceId = $id; KeyExisted = $false; DevicePolicy = $null; Override = $null }
            [void]$rows.Add((New-PcbIrqRow 'irq' $item '?' '?' ('FAIL: read pin ' + $_.Exception.Message)))
            [void]$errors.Add('read pin ' + $id + ': ' + $_.Exception.Message)
        }
        $rec | Add-Member -NotePropertyName Extras -NotePropertyValue @() -Force
        $rec | Add-Member -NotePropertyName CreatedKeys -NotePropertyValue @() -Force
        [void]$before.Add($rec)
        $beforeText = Format-PcbIrqPin $rec.DevicePolicy $rec.Override

        $cpu = $null
        try { $cpu = Get-PcbIrqCpuForRole $IrqMask $role } catch { $cpu = $null }
        if ($cpu -eq $null) {
            [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText '<none>' 'SKIP: no free core'))
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText '<none>' 'SKIP: no free core'))
            continue
        }
        if ([int]$cpu -ge $ncpu) {
            $m = 'cpu ' + $cpu + ' not present (' + $ncpu + ' logical processors)'
            [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText '<none>' ('FAIL: ' + $m)))
            [void]$errors.Add($id + ': ' + $m)
            continue
        }

        $want = Get-PcbIrqBytes ([int]$cpu)
        $afterText = 'DP=4 OV=[' + ((@($want) | ForEach-Object { [int]$_ }) -join ',') + '] CPU' + $cpu

        # The extra values this device gets. Planned up front so -DryRun can print
        # them; the before state is read at write time, not here.
        $plan = @()
        try { $plan = @(Get-PcbIrqExtraPlan $role $id) } catch {
            [void]$errors.Add($id + ': plan extras ' + $_.Exception.Message)
        }

        if ($DryRun) {
            [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText $afterText ('OK (dry-run) cpu ' + $cpu)))
            foreach ($p in $plan) {
                if ($p -eq $null) { continue }
                $st = Read-PcbIrqExtraState ([string]$p.Path) ([string]$p.Name)
                $bf = '<absent>'
                if ($st.Existed) { $bf = '' + $st.Value }
                [void]$rows.Add((New-PcbIrqRow 'value' $item $bf ('' + $p.Value) ('OK (dry-run) ' + [string]$p.Name)))
            }
            $rst = 'DRYRUN: restart skipped'
            if ($NoRestart) { $rst = 'SKIP: no restart requested' }
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText $rst))
            Write-PcbIrqOut ('  dry-run ' + $item + ' : pin ' + $beforeText + ' -> ' + $afterText + ' (no write)')
            foreach ($p in $plan) {
                if ($p -eq $null) { continue }
                $st = Read-PcbIrqExtraState ([string]$p.Path) ([string]$p.Name)
                $bf = '<absent>'
                if ($st.Existed) { $bf = '' + $st.Value }
                Write-PcbIrqOut ('    ' + [string]$p.Name + ': ' + $bf + ' -> ' + ('' + $p.Value))
            }
            continue
        }

        # 1. the pin, 2. the extra values - both before the restart, so the driver
        # reads the whole set when the device starts again.
        try {
            $null = Write-PcbIrqPinValues $id 4 $want
            $chk = Read-PcbIrqPin $id
            $okWrite = $false
            if ($chk.DevicePolicy -eq 4 -and $chk.Override -ne $null -and @($chk.Override).Count -eq 8) {
                $okWrite = $true
                for ($i = 0; $i -lt 8; $i++) { if ([int]$chk.Override[$i] -ne [int]$want[$i]) { $okWrite = $false } }
            }
            $readBack = Format-PcbIrqPin $chk.DevicePolicy $chk.Override
            if ($okWrite) {
                [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText $readBack ('OK cpu ' + $cpu)))
            } else {
                [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText $readBack ('FAIL: readback mismatch, want ' + $afterText)))
                [void]$errors.Add($id + ': readback mismatch')
            }
        } catch {
            [void]$rows.Add((New-PcbIrqRow 'irq' $item $beforeText $afterText ('FAIL: write pin ' + $_.Exception.Message)))
            [void]$errors.Add($id + ': write pin ' + $_.Exception.Message)
        }

        if ($plan.Count -gt 0) {
            try {
                $wr = Write-PcbIrqExtraPlan $plan
                $rec.Extras = @($wr.Entries)
                $rec.CreatedKeys = @($wr.CreatedKeys)
                foreach ($e in @($wr.Entries)) {
                    if ($e -eq $null) { continue }
                    $bf = '<absent>'
                    if ($e.Existed -eq $true) { $bf = '' + $e.Before }
                    [void]$rows.Add((New-PcbIrqRow 'value' $item $bf ('' + $e.After) ('OK ' + [string]$e.Name)))
                }
            } catch {
                [void]$rows.Add((New-PcbIrqRow 'value' $item '?' '?' ('FAIL: write extras ' + $_.Exception.Message)))
                [void]$errors.Add($id + ': write extras ' + $_.Exception.Message)
            }
        }

        if ($NoRestart) {
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText 'SKIP: no restart requested'))
            continue
        }
        try {
            $r = Invoke-PcbIrqRestart $role $id
            $status = [string]$r.Status
            if ($status -like 'FAIL*') {
                # 3. auto-rollback: put the pin and the extras back and restart once more.
                $reason = $status -replace '^FAIL:\s*', ''
                try {
                    $null = Write-PcbIrqPinValues $id $rec.DevicePolicy $rec.Override
                    $null = Restore-PcbIrqExtras $rec.Extras $rec.CreatedKeys
                } catch {
                    [void]$errors.Add($id + ': rollback write ' + $_.Exception.Message)
                }
                $r2 = $null
                try { $r2 = Invoke-PcbIrqRestart $role $id } catch {
                    [void]$errors.Add($id + ': rollback restart ' + $_.Exception.Message)
                }
                $s2 = ''
                if ($r2 -ne $null) { $s2 = [string]$r2.Status }
                $msi2 = ''
                try { $msi2 = (Get-PcbIrqInterruptType $id).Text } catch { $msi2 = 'msi=?' }
                Write-PcbIrqOut ('  ' + $id + ' -> ' + $msi2)
                if ($s2 -like 'FAIL*') {
                    $st2 = 'FAIL: rollback restart failed (' + $reason + ')'
                    [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText $st2 $msi2))
                    [void]$errors.Add($id + ': ' + $st2 + ' ; second ' + $s2)
                } else {
                    $st1 = 'FAIL: rolled back (' + $reason + ')'
                    [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText $st1 $msi2))
                    [void]$errors.Add($id + ': ' + $st1)
                }
            } else {
                $msiText = ''
                try { $msiText = (Get-PcbIrqInterruptType $id).Text } catch { $msiText = 'msi=?' }
                [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText $status $msiText))
                Write-PcbIrqOut ('  ' + $id + ' -> ' + $msiText)
            }
        } catch {
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $beforeText $afterText ('FAIL: restart ' + $_.Exception.Message)))
            [void]$errors.Add($id + ': restart ' + $_.Exception.Message)
        }
    }

    $ok = $true
    foreach ($r in $rows) { if ($r.Status -like 'FAIL*') { $ok = $false } }
    return [pscustomobject]@{
        Ok     = $ok
        Before = @($before.ToArray())
        Rows   = @($rows.ToArray())
        Error  = ($errors -join ' | ')
    }
}

function Restore-PcbIrqPins {
    param(
        $Before = $null,
        [switch]$NoRestart
    )

    $rows = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $records = @()
    if ($Before -ne $null) { $records = @($Before) }

    foreach ($rec in $records) {
        if ($rec -eq $null) { continue }
        $role = [string]$rec.Role
        $id = [string]$rec.InstanceId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $item = $role + ' ' + $id
        $wantDP = $rec.DevicePolicy
        $wantOV = $rec.Override
        $cur = $null
        try { $cur = Read-PcbIrqPin $id } catch { $cur = $null }
        $curText = 'unknown'
        if ($cur -ne $null) { $curText = Format-PcbIrqPin $cur.DevicePolicy $cur.Override }
        $targetText = Format-PcbIrqPin $wantDP $wantOV

        try {
            if ($rec.KeyExisted -eq $false) {
                # key did not exist before: leave the key, drop both values
                $null = Write-PcbIrqPinValues $id $null $null
                $chk = Read-PcbIrqPin $id
                $rb = Format-PcbIrqPin $chk.DevicePolicy $chk.Override
                if ($chk.DevicePolicy -eq $null -and $chk.Override -eq $null) {
                    [void]$rows.Add((New-PcbIrqRow 'irq' $item $curText $rb 'OK'))
                } else {
                    [void]$rows.Add((New-PcbIrqRow 'irq' $item $curText $rb 'FAIL: values still present'))
                    [void]$errors.Add($id + ': restore left values')
                }
            } else {
                $null = Write-PcbIrqPinValues $id $wantDP $wantOV
                $chk = Read-PcbIrqPin $id
                $rb = Format-PcbIrqPin $chk.DevicePolicy $chk.Override
                $okW = $false
                if ($wantDP -eq $null) {
                    $okW = ($chk.DevicePolicy -eq $null)
                } else {
                    $okW = ($chk.DevicePolicy -ne $null -and [int]$chk.DevicePolicy -eq [int]$wantDP)
                }
                if ($okW -and $wantOV -ne $null) {
                    if ($chk.Override -eq $null -or @($chk.Override).Count -ne @($wantOV).Count) {
                        $okW = $false
                    } else {
                        $n = @($wantOV).Count
                        for ($i = 0; $i -lt $n; $i++) {
                            if ([int]$chk.Override[$i] -ne [int](@($wantOV)[$i])) { $okW = $false }
                        }
                    }
                }
                if ($okW -and $wantOV -eq $null -and $chk.Override -ne $null) { $okW = $false }
                if ($okW) {
                    [void]$rows.Add((New-PcbIrqRow 'irq' $item $curText $rb 'OK'))
                } else {
                    [void]$rows.Add((New-PcbIrqRow 'irq' $item $curText $rb ('FAIL: readback mismatch, want ' + $targetText)))
                    [void]$errors.Add($id + ': restore readback mismatch')
                }
            }
        } catch {
            [void]$rows.Add((New-PcbIrqRow 'irq' $item $curText $targetText ('FAIL: restore pin ' + $_.Exception.Message)))
            [void]$errors.Add($id + ': restore pin ' + $_.Exception.Message)
        }

        # The extra values come back before the restart, so the driver re-reads the
        # pre-kit state when the device starts again.
        $extras = @()
        try {
            $p = $rec.PSObject.Properties['Extras']
            if ($p -ne $null -and $p.Value -ne $null) { $extras = @($p.Value) }
        } catch { $extras = @() }
        $createdKeys = @()
        try {
            $p = $rec.PSObject.Properties['CreatedKeys']
            if ($p -ne $null -and $p.Value -ne $null) { $createdKeys = @($p.Value) }
        } catch { $createdKeys = @() }
        if ($extras.Count -gt 0 -or $createdKeys.Count -gt 0) {
            try {
                $bad = @(Restore-PcbIrqExtras $extras $createdKeys)
                if ($bad.Count -eq 0) {
                    [void]$rows.Add((New-PcbIrqRow 'value' $item ('' + $extras.Count) '0' 'OK restored'))
                } else {
                    [void]$rows.Add((New-PcbIrqRow 'value' $item '?' '?' ('FAIL: ' + ($bad -join ' | '))))
                    [void]$errors.Add($id + ': restore extras ' + ($bad -join ' | '))
                }
            } catch {
                [void]$rows.Add((New-PcbIrqRow 'value' $item '?' '?' ('FAIL: restore extras ' + $_.Exception.Message)))
                [void]$errors.Add($id + ': restore extras ' + $_.Exception.Message)
            }
        }

        # The pin branch may have created the Affinity Policy key before the extras were
        # planned, so it was never recorded as created. The device's key chain did not
        # exist before the kit, so take the now-empty leftovers away too.
        if ($rec.KeyExisted -eq $false) {
            try { Remove-PcbIrqEmptyKeyChain (Get-PcbIrqApKey $id) } catch { }
        }

        if ($NoRestart) {
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $curText $targetText 'SKIP: no restart requested'))
            continue
        }
        try {
            $r = Invoke-PcbIrqRestart $role $id
            $msiR = ''
            try { $msiR = (Get-PcbIrqInterruptType $id).Text } catch { $msiR = 'msi=?' }
            Write-PcbIrqOut ('  ' + $id + ' -> ' + $msiR)
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $curText $targetText $r.Status $msiR))
            if ($r.Status -like 'FAIL*') { [void]$errors.Add($id + ': ' + $r.Status) }
        } catch {
            [void]$rows.Add((New-PcbIrqRow 'restart' $item $curText $targetText ('FAIL: restart ' + $_.Exception.Message)))
            [void]$errors.Add($id + ': restart ' + $_.Exception.Message)
        }
    }

    $ok = $true
    foreach ($r in $rows) { if ($r.Status -like 'FAIL*') { $ok = $false } }
    return [pscustomobject]@{
        Ok     = $ok
        Before = @()
        Rows   = @($rows.ToArray())
        Error  = ($errors -join ' | ')
    }
}

# ==== end irq.ps1 ====

# ==== begin timer.ps1 ====
# W-PCB7A - high resolution timer hold for the PC-bang kit.
# Pure Windows PowerShell 5.1, single file, ASCII only, no exe, no network.
#
# Public API:
#   Start-PcbTimerHold [-Resolution <100ns units>]  -> Ok / Min / Max / Current / ThrottleOptOut / Error
#   Get-PcbTimerResolution                          -> Min / Max / Current   (ntdll, no side effect)
#   Format-PcbTimerMs <units>                       -> '0.507 ms'
#
# Why: Windows only honours a requested timer resolution on the thread that asked for
# it, and a background process on Windows 11 normally gets its request clamped by power
# throttling.  Opting out of PROCESS_POWER_THROTTLING (EXECUTION_SPEED +
# IGNORE_TIMER_RESOLUTION) and then asking ntdll for 5000 units gives the whole session
# a 0.5 ms system timer while this process stays alive.  Measured on this PC: with the
# holder running NtQueryTimerResolution reports 5000, and it drops back to 5070 within
# one second of the holder exiting, so the hold needs a process that lives for the
# session - the watcher (step h) is exactly that process.
#
# Nothing here throws: every failure comes back with Ok=$false and an Error string.

$script:PcbTimerCs = @'
using System;
using System.Runtime.InteropServices;

public static class PcbTimer
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_POWER_THROTTLING_STATE
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr hProcess, int infoClass,
        ref PROCESS_POWER_THROTTLING_STATE info, int size);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(uint desired, bool set, out uint current);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(out uint min, out uint max, out uint current);

    // ControlMask 0x5 = EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION, StateMask 0 clears
    // both, i.e. this process opts out of the throttle it would otherwise get.
    public static bool OptOutOfThrottling()
    {
        PROCESS_POWER_THROTTLING_STATE st = new PROCESS_POWER_THROTTLING_STATE();
        st.Version = 1;
        st.ControlMask = 0x5;
        st.StateMask = 0;
        return SetProcessInformation(GetCurrentProcess(), 4, ref st,
            Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE)));
    }
}
'@

function Initialize-PcbTimerNative {
  if (-not ('PcbTimer' -as [type])) {
    Add-Type -TypeDefinition $script:PcbTimerCs -ErrorAction Stop
  }
  return $true
}

function Get-PcbTimerResolution {
  $rec = @{ Ok = $false; Min = 0; Max = 0; Current = 0; Error = '' }
  try {
    if (-not (Initialize-PcbTimerNative)) { return $rec }
    $mn = [uint32]0
    $mx = [uint32]0
    $cu = [uint32]0
    $st = [PcbTimer]::NtQueryTimerResolution([ref]$mn, [ref]$mx, [ref]$cu)
    $rec.Ok = ($st -eq 0)
    $rec.Min = [int]$mn
    $rec.Max = [int]$mx
    $rec.Current = [int]$cu
    if ($st -ne 0) { $rec.Error = 'NtQueryTimerResolution status 0x' + ('{0:X8}' -f $st) }
  } catch {
    $rec.Error = $_.Exception.Message
  }
  return [pscustomobject]$rec
}

function Format-PcbTimerMs([int]$Units) {
  if ($Units -le 0) { return 'n/a' }
  # 100 ns units -> milliseconds, three decimals is enough for 0.507
  $ms = [double]$Units / 10000.0
  return ('{0:0.000} ms' -f $ms)
}

function Start-PcbTimerHold {
  param([int]$Resolution = 5070)
  $rec = [pscustomobject]@{ Ok = $false; Min = 0; Max = 0; Current = 0; ThrottleOptOut = $false; Error = '' }
  try {
    if (-not (Initialize-PcbTimerNative)) { $rec.Error = 'Add-Type failed'; return $rec }
    try { $rec.ThrottleOptOut = [bool][PcbTimer]::OptOutOfThrottling() } catch { $rec.ThrottleOptOut = $false }
    $cur = [uint32]0
    $st = [PcbTimer]::NtSetTimerResolution([uint32]$Resolution, $true, [ref]$cur)
    $rec.Current = [int]$cur
    if ($st -ne 0) {
      $rec.Error = 'NtSetTimerResolution status 0x' + ('{0:X8}' -f $st)
    } else {
      $rec.Ok = $true
    }
    $q = Get-PcbTimerResolution
    if ($q.Ok) {
      $rec.Min = [int]$q.Min
      $rec.Max = [int]$q.Max
      $rec.Current = [int]$q.Current
    }
  } catch {
    $rec.Ok = $false
    $rec.Error = $_.Exception.Message
  }
  return $rec
}

# ==== end timer.ps1 ====

# ==== begin gpuclock.ps1 ====
# W-PCB7A - GPU clock / power lock for the PC-bang kit (nvidia-smi wrapper).
# Pure Windows PowerShell 5.1, single file, ASCII only, no network.
#
# Public API:
#   Get-PcbGpuClockState              -> Available / Exe / Before{...} / Error
#   Set-PcbGpuClock [-State <s>]      -> Ok / Rows[{Item,Before,After,Status}] / Applied / Error
#   Restore-PcbGpuClock -Rec <r>      -> Ok / Rows[{...}] / Error
#
# The home script wrote fixed constants (-pl 140, -lgc 2012,2012, -lmc 4004,4004,
# -ac 2012,4004, -pm 1).  This module reads the card's own maxima and mirrors the same
# commands with them, so the kit is right on any card instead of only this 1060.
#
# Measured on this PC (GTX 1060, driver 32.0.15.8253):
#   power.max_limit 140 W, clocks.max.graphics 2012 MHz, clocks.max.memory 4004 MHz
#   -pl      -> honoured ("was set to 140.00 W"), read back from power.limit
#   -lgc/-lmc/-ac -> "Setting locked ... is not supported for GPU", rc 0 -> SKIP row
#   -pm 1    -> "not supported ... on this platform" (Linux only) -> SKIP row
#
# The runner is injectable: $script:PcbNvSmiRunner receives an argument array and must
# return @{ Output = '<text>'; Code = <int> }.  Tests replace it so nothing is executed.
#
# Nothing here throws: every failure comes back with Ok=$false and an Error string.

$script:PcbNvSmiRunner = $null

function Get-PcbNvSmiExe {
  $cands = New-Object System.Collections.ArrayList
  [void]$cands.Add((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'))
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    [void]$cands.Add((Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))
  }
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramW6432})) {
    [void]$cands.Add((Join-Path ${env:ProgramW6432} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'))
  }
  foreach ($c in $cands) {
    if (Test-Path -LiteralPath $c) { return $c }
  }
  return $null
}

function Invoke-PcbNvSmi {
  param([string[]]$Arguments)
  if ($null -ne $script:PcbNvSmiRunner) {
    $r = & $script:PcbNvSmiRunner $Arguments
    $out = ''
    $code = 0
    if ($null -ne $r) {
      if ($r -is [hashtable] -or $r.PSObject.Properties['Output']) {
        $out = [string]$r.Output
        if ($null -ne $r.Code) { $code = [int]$r.Code }
      } else {
        $out = [string]$r
      }
    }
    return [pscustomobject]@{ Output = $out; Code = $code }
  }
  $exe = Get-PcbNvSmiExe
  if ($null -eq $exe) { return [pscustomobject]@{ Output = ''; Code = -1 } }
  $txt = ''
  try {
    $txt = (@(& $exe @Arguments 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    $rc = $LASTEXITCODE
  } catch {
    return [pscustomobject]@{ Output = $_.Exception.Message; Code = -1 }
  }
  return [pscustomobject]@{ Output = $txt; Code = [int]$rc }
}

# '120.00 W, 120.00 W, 140.00 W, 2012 MHz, 4004 MHz' -> same shape as a list of numbers
function ConvertFrom-PcbNvNum([string]$Text) {
  $m = [regex]::Match([string]$Text, '([0-9]+(?:\.[0-9]+)?)')
  if ($m.Success) {
    $v = 0.0
    if ([double]::TryParse($m.Groups[1].Value, [ref]$v)) { return $v }
  }
  return $null
}

function Get-PcbGpuClockState {
  $rec = [pscustomobject]@{
    Available = $false
    Exe       = ''
    Before    = $null
    Error     = ''
  }
  try {
    $exe = Get-PcbNvSmiExe
    if ($null -ne $script:PcbNvSmiRunner -or $null -ne $exe) { $rec.Available = $true }
    $rec.Exe = [string]$exe
    if (-not $rec.Available) {
      $rec.Error = 'nvidia-smi.exe not found'
      return $rec
    }
    $q = Invoke-PcbNvSmi @('--query-gpu=power.limit,power.default_limit,power.max_limit,clocks.max.graphics,clocks.max.memory', '--format=csv,noheader')
    $line = ''
    foreach ($l in ([string]$q.Output).Split("`n")) {
      $t = $l.Trim()
      if ($t.Length -gt 0) { $line = $t; break }
    }
    if ($line.Length -eq 0) {
      $rec.Available = $false
      $rec.Error = 'nvidia-smi returned no data (rc ' + $q.Code + ')'
      return $rec
    }
    $parts = @($line.Split(','))
    if ($parts.Count -lt 5) {
      $rec.Available = $false
      $rec.Error = 'unexpected nvidia-smi row: ' + $line
      return $rec
    }
    $rec.Before = [pscustomobject]@{
      PowerLimit    = ConvertFrom-PcbNvNum $parts[0]
      DefaultLimit  = ConvertFrom-PcbNvNum $parts[1]
      MaxLimit      = ConvertFrom-PcbNvNum $parts[2]
      MaxGraphics   = ConvertFrom-PcbNvNum $parts[3]
      MaxMemory     = ConvertFrom-PcbNvNum $parts[4]
    }
    if ($null -eq $rec.Before.MaxLimit -or $null -eq $rec.Before.MaxGraphics -or $null -eq $rec.Before.MaxMemory) {
      $rec.Available = $false
      $rec.Error = 'could not parse nvidia-smi row: ' + $line
      return $rec
    }
  } catch {
    $rec.Available = $false
    $rec.Error = $_.Exception.Message
  }
  return $rec
}

function Format-PcbNvNum($Value, [string]$Suffix) {
  if ($null -eq $Value) { return 'n/a' }
  return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.##}', [double]$Value) + $Suffix)
}

# The stored record reaches Restore-PcbGpuClock in two shapes: the hashtable main.ps1
# builds in memory, and the PSCustomObject that ConvertFrom-Json returns after the state
# file is reloaded on a revert run.  $Rec.PSObject.Properties[...] is empty for a
# hashtable, so reading the record any other way silently skips every revert.
function Get-PcbRecValue($Rec, [string]$Name) {
  if ($null -eq $Rec) { return $null }
  if ($Rec -is [System.Collections.IDictionary]) {
    if ($Rec.Contains($Name)) { return $Rec[$Name] }
    return $null
  }
  $p = $Rec.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

# A non-zero exit or a 'not supported' / 'warning' banner means the card refused the
# command; that is a SKIP row, never an OK one.
function Test-PcbNvRejected($Result) {
  $t = [string]$Result.Output
  if ([int]$Result.Code -ne 0) { return $true }
  if ($t -match '(?i)not supported') { return $true }
  if ($t -match '(?i)does not support') { return $true }
  if ($t -match '(?i)^\s*NVIDIA\s+SMI\s+has\s+failed') { return $true }
  if ($t -match '(?i)insufficient permissions') { return $true }
  return $false
}

function Get-PcbNvMsg([string]$Text) {
  foreach ($l in ([string]$Text).Split("`n")) {
    $t = $l.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t -match '(?i)^All done\.?$') { continue }
    return $t
  }
  return 'no output'
}

function Read-PcbGpuLiveRow {
  $q = Invoke-PcbNvSmi @('--query-gpu=power.limit,clocks.gr,clocks.mem', '--format=csv,noheader')
  foreach ($l in ([string]$q.Output).Split("`n")) {
    $t = $l.Trim()
    if ($t.Length -gt 0) { return $t }
  }
  return ''
}

function Set-PcbGpuClock {
  param($State)
  $rows = New-Object System.Collections.ArrayList
  $rec = [pscustomobject]@{ Ok = $false; Rows = @(); Applied = $null; Error = '' }
  $applied = [pscustomobject]@{ PowerLimit = $null; LockedGfx = $false; LockedMem = $false; AppClocks = $false }
  try {
    if ($null -eq $State) { $State = Get-PcbGpuClockState }
    if ($null -eq $State -or -not $State.Available) {
      $msg = 'nvidia-smi unavailable'
      if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace([string]$State.Error)) { $msg = [string]$State.Error }
      [void]$rows.Add([pscustomobject]@{ Item = 'gpu/clock'; Before = 'n/a'; After = 'n/a'; Status = ('SKIP: ' + $msg) })
      $rec.Rows = @($rows)
      $rec.Error = $msg
      return $rec
    }
    $b = $State.Before
    $plWant = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.##}', [double]$b.MaxLimit)
    $grWant = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0}', [double]$b.MaxGraphics)
    $memWant = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0}', [double]$b.MaxMemory)
    $beforePl = Format-PcbNvNum $b.PowerLimit ' W'

    # -pl: the one command this card honours.  Verified by reading power.limit back.
    $r = Invoke-PcbNvSmi @('-pl', $plWant)
    if (Test-PcbNvRejected $r) {
      [void]$rows.Add([pscustomobject]@{ Item = 'gpu/power-limit'; Before = $beforePl; After = $beforePl; Status = ('SKIP: ' + (Get-PcbNvMsg $r.Output)) })
    } else {
      $live = Read-PcbGpuLiveRow
      $livePl = ConvertFrom-PcbNvNum ((@($live.Split(','))[0]))
      $applied.PowerLimit = $b.PowerLimit
      $afterPl = Format-PcbNvNum $livePl ' W'
      $st = 'OK'
      if ($null -eq $livePl -or [double]$livePl -ne [double]$b.MaxLimit) { $st = 'OK (written)' }
      [void]$rows.Add([pscustomobject]@{ Item = 'gpu/power-limit'; Before = $beforePl; After = $afterPl; Status = $st })
    }

    # -lgc / -lmc / -ac: refused outright on a GeForce card, so the row carries the
    # driver's own words.  Revert only runs for the ones that were accepted.
    $lockSpecs = @(
      @{ Item = 'gpu/lock-gfx'; Args = @('-lgc', ($grWant + ',' + $grWant)); Flag = 'LockedGfx'; Want = $grWant },
      @{ Item = 'gpu/lock-mem'; Args = @('-lmc', ($memWant + ',' + $memWant)); Flag = 'LockedMem'; Want = $memWant },
      @{ Item = 'gpu/app-clock'; Args = @('-ac', ($memWant + ',' + $grWant)); Flag = 'AppClocks'; Want = ($grWant + '/' + $memWant) }
    )
    foreach ($spec in $lockSpecs) {
      $r = Invoke-PcbNvSmi $spec.Args
      if (Test-PcbNvRejected $r) {
        [void]$rows.Add([pscustomobject]@{ Item = $spec.Item; Before = 'unset'; After = 'unset'; Status = ('SKIP: ' + (Get-PcbNvMsg $r.Output)) })
        continue
      }
      $applied.($spec.Flag) = $true
      $live = Read-PcbGpuLiveRow
      $st = 'OK (written)'
      if ($spec.Item -eq 'gpu/lock-gfx' -and $live.Length -gt 0) {
        $curGr = ConvertFrom-PcbNvNum ((@($live.Split(','))[1]))
        if ($null -ne $curGr) { $st = 'OK (read-back ' + (Format-PcbNvNum $curGr ' MHz') + ')' }
      }
      [void]$rows.Add([pscustomobject]@{ Item = $spec.Item; Before = 'unset'; After = [string]$spec.Want; Status = $st })
    }

    # -pm is Linux-only; this card answers "not supported ... on this platform".
    $r = Invoke-PcbNvSmi @('-pm', '1')
    if (Test-PcbNvRejected $r) {
      [void]$rows.Add([pscustomobject]@{ Item = 'gpu/persistence-mode'; Before = 'n/a'; After = 'n/a'; Status = ('SKIP: ' + (Get-PcbNvMsg $r.Output)) })
    } else {
      [void]$rows.Add([pscustomobject]@{ Item = 'gpu/persistence-mode'; Before = 'n/a'; After = '1'; Status = 'OK (written)' })
    }

    $rec.Ok = $true
    $rec.Applied = $applied
    $rec.Rows = @($rows)
  } catch {
    $rec.Ok = $false
    $rec.Error = $_.Exception.Message
    [void]$rows.Add([pscustomobject]@{ Item = 'gpu/clock'; Before = 'unknown'; After = 'unknown'; Status = ('FAIL: ' + $_.Exception.Message) })
    $rec.Rows = @($rows)
  }
  return $rec
}

function Restore-PcbGpuClock {
  param($Rec)
  $rows = New-Object System.Collections.ArrayList
  $out = [pscustomobject]@{ Ok = $false; Rows = @(); Error = '' }
  try {
    if ($null -eq $Rec) { $out.Error = 'nothing recorded'; $out.Rows = @(); return $out }
    $recPl = Get-PcbRecValue $Rec 'PowerLimit'
    if ($null -ne $recPl) {
      $want = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.##}', [double]$recPl)
      $r = Invoke-PcbNvSmi @('-pl', $want)
      $live = Read-PcbGpuLiveRow
      $livePl = $null
      if ($live.Length -gt 0) { $livePl = ConvertFrom-PcbNvNum ((@($live.Split(','))[0])) }
      if (Test-PcbNvRejected $r) {
        [void]$rows.Add([pscustomobject]@{ Item = 'gpu/power-limit'; Before = '(tuned)'; After = (Format-PcbNvNum $livePl ' W'); Status = ('SKIP: ' + (Get-PcbNvMsg $r.Output)) })
      } elseif ($null -ne $livePl -and [double]$livePl -eq [double]$recPl) {
        [void]$rows.Add([pscustomobject]@{ Item = 'gpu/power-limit'; Before = '(tuned)'; After = (Format-PcbNvNum $livePl ' W'); Status = 'OK' })
      } else {
        [void]$rows.Add([pscustomobject]@{ Item = 'gpu/power-limit'; Before = '(tuned)'; After = (Format-PcbNvNum $livePl ' W'); Status = 'FAIL: read-back differs' })
      }
    }
    foreach ($spec in @(
      @{ Item = 'gpu/lock-gfx'; Flag = 'LockedGfx'; Arg = '-rgc' },
      @{ Item = 'gpu/lock-mem'; Flag = 'LockedMem'; Arg = '-rmc' },
      @{ Item = 'gpu/app-clock'; Flag = 'AppClocks'; Arg = '-rac' }
    )) {
      if (-not [bool](Get-PcbRecValue $Rec $spec.Flag)) { continue }
      $r = Invoke-PcbNvSmi @($spec.Arg)
      if (Test-PcbNvRejected $r) {
        [void]$rows.Add([pscustomobject]@{ Item = $spec.Item; Before = '(tuned)'; After = '(tuned)'; Status = ('SKIP: ' + (Get-PcbNvMsg $r.Output)) })
      } else {
        [void]$rows.Add([pscustomobject]@{ Item = $spec.Item; Before = '(tuned)'; After = 'unset'; Status = 'OK (written)' })
      }
    }
    $out.Ok = $true
    $out.Rows = @($rows)
  } catch {
    $out.Ok = $false
    $out.Error = $_.Exception.Message
  }
  return $out
}

# ==== end gpuclock.ps1 ====

# ==== begin lolcfg.ps1 ====
# W-PCB7A - League of Legends game.cfg / PersistedSettings.json tuning.
# Pure Windows PowerShell 5.1, single file, ASCII only, no network.
#
# Public API:
#   Get-PcbLolCfgDir                                    -> path or $null
#   Get-PcbLolCfgState [-Dir <d>]                       -> Available / Dir / Rows / Error
#   Set-PcbLolCfg    [-State <s>] [-BackupDir <d>]      -> Ok / Rows / Backup / Applied / Error
#   Restore-PcbLolCfg -Rec <r>                          -> Ok / Rows / Error
#   $script:PcbLolCfgDir    - override the Config dir (tests point this at a temp copy)
#   $script:PcbLolCfgValues - the row table (Value = live home value)
#
# Only four groups are written (REPORT-W-INV1 rows 54, 55, 56, 58); mouse speed and the
# colour block (rows 57 and 59) are personal settings and stay out.
#
# game.cfg is an INI-ish key=value file; PersistedSettings.json repeats the same names
# under files[].sections[].settings[] with every value as a STRING.  Both are edited in
# place, byte for byte.  The original bytes are copied into the state dir before
# anything is written and a revert copies them back, so the restore is exact.
#
# Nothing here throws: every failure comes back with Ok=$false and an Error string.

$script:PcbLolCfgDir = $null

# Values come from the LIVE home file (C:\Riot Games\League of Legends\Config\game.cfg),
# not from cfg.ps1 - two of cfg.ps1's values did not stick at home.
$script:PcbLolCfgValues = @(
  @{ Section = 'General';     Name = 'WindowMode';          Value = '0' },
  @{ Section = 'General';     Name = 'WaitForVerticalSync'; Value = '0' },
  @{ Section = 'General';     Name = 'PredictMovement';     Value = '0' },
  @{ Section = 'Performance'; Name = 'FrameCapType';        Value = '10' }
)

$script:PcbLolCfgFiles = @('game.cfg', 'PersistedSettings.json')

function Get-PcbLolCfgDir {
  if (-not [string]::IsNullOrWhiteSpace([string]$script:PcbLolCfgDir)) { return [string]$script:PcbLolCfgDir }
  if (-not (Get-Command Get-PcbLolExe -ErrorAction SilentlyContinue)) { return $null }
  $exe = $null
  try { $exe = Get-PcbLolExe } catch { $exe = $null }
  if ([string]::IsNullOrWhiteSpace([string]$exe)) { return $null }
  # <install>\Game\League of Legends.exe -> <install>\Config
  $gameDir = Split-Path -Parent ([string]$exe)
  $root = Split-Path -Parent $gameDir
  if ([string]::IsNullOrWhiteSpace($root)) { return $null }
  return (Join-Path $root 'Config')
}

function Test-PcbLolRunning {
  foreach ($n in @('League of Legends', 'LeagueClient', 'LeagueClientUx')) {
    if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  }
  return $false
}

# Reads Name=Value out of an INI-ish file plus the line separator it uses, so a writer
# can put the file back together byte-identically.
function Read-PcbLolCfgIni([string]$Path) {
  $rec = [pscustomobject]@{ Existed = $false; Text = ''; Sep = "`r`n"; Values = @{}; Error = '' }
  if (-not (Test-Path -LiteralPath $Path)) { return $rec }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $rec.Existed = $true
    $rec.Text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $crlf = ([regex]::Matches($rec.Text, "`r`n")).Count
    $lf = ([regex]::Matches($rec.Text, "(?<!`r)`n")).Count
    if ($lf -gt $crlf) { $rec.Sep = "`n" }
    $sec = ''
    foreach ($ln in [regex]::Split($rec.Text, '\r\n|\n|\r')) {
      $t = $ln.Trim()
      if ($t.Length -eq 0) { continue }
      if ($t.StartsWith('[')) {
        $m = [regex]::Match($t, '^\[([^\]]+)\]')
        if ($m.Success) { $sec = $m.Groups[1].Value }
        continue
      }
      $eq = $t.IndexOf('=')
      if ($eq -le 0) { continue }
      $k = $t.Substring(0, $eq).Trim()
      $v = $t.Substring($eq + 1).Trim()
      $rec.Values[$sec + '/' + $k] = $v
    }
  } catch {
    $rec.Error = $_.Exception.Message
  }
  return $rec
}

function Get-PcbLolCfgState {
  param([string]$Dir = '')
  $rec = [pscustomobject]@{ Available = $false; Dir = ''; Sep = "`r`n"; Rows = @(); Error = '' }
  try {
    $d = $Dir
    if ([string]::IsNullOrWhiteSpace($d)) { $d = Get-PcbLolCfgDir }
    $rec.Dir = [string]$d
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) {
      $rec.Error = 'Config dir not found'
      return $rec
    }
    $cfg = Read-PcbLolCfgIni (Join-Path $d 'game.cfg')
    if (-not $cfg.Existed) {
      $rec.Error = 'game.cfg not found'
      return $rec
    }
    $rec.Sep = [string]$cfg.Sep
    $rec.Available = $true
    $rows = New-Object System.Collections.ArrayList
    foreach ($v in $script:PcbLolCfgValues) {
      $key = $v.Section + '/' + $v.Name
      $cur = '(absent)'
      if ($cfg.Values.ContainsKey($key)) { $cur = [string]$cfg.Values[$key] }
      [void]$rows.Add([pscustomobject]@{ Section = $v.Section; Name = $v.Name; Before = $cur; Want = [string]$v.Value })
    }
    $rec.Rows = @($rows)
  } catch {
    $rec.Available = $false
    $rec.Error = $_.Exception.Message
  }
  return $rec
}

# Replaces the value bytes of 'Name=old' inside a section and nothing else.
#
# The split pattern captures the line breaks, so the pieces alternate between
# line-content and terminator: even indices are content, odd indices are the exact
# terminator that line had.  Only an even index is ever written, and the join puts the
# terminators back untouched, so a file with 201 CRLF and 6 lone LF still has 201 CRLF
# and 6 lone LF afterwards, on the same lines, and a file with no trailing newline keeps
# having none.  (The previous version split with a non-capturing pattern and re-joined
# with one separator, which turned every apply into an all-CRLF rewrite of the file.)
#
# $Sep is kept for call compatibility; it is no longer used.
function Set-PcbLolCfgIniValue([string]$Text, [string]$Section, [string]$Name, [string]$Value, [string]$Sep) {
  $parts = [regex]::Split($Text, '(\r\n|\n|\r)')
  $sec = ''
  for ($i = 0; $i -lt $parts.Count; $i += 2) {
    $raw = [string]$parts[$i]
    $t = $raw.Trim()
    if ($t.StartsWith('[')) {
      $m = [regex]::Match($t, '^\[([^\]]+)\]')
      if ($m.Success) { $sec = $m.Groups[1].Value }
      continue
    }
    if ($sec -ne $Section) { continue }
    $eq = $t.IndexOf('=')
    if ($eq -le 0) { continue }
    if ($t.Substring(0, $eq).Trim() -ne $Name) { continue }
    $rawEq = $raw.IndexOf('=')
    if ($rawEq -lt 0) { continue }
    $newRaw = $raw.Substring(0, $rawEq + 1) + $Value
    if ($newRaw -ne $raw) { $parts[$i] = $newRaw }
    return ($parts -join '')
  }
  return $Text
}

# PersistedSettings.json holds the same names as ["name": X, "value": "Y"] pairs.
# A hand-rolled two-step replace keeps the file's layout and encoding intact.
function Set-PcbLolPersistedValue([string]$Text, [string]$Name, [string]$Value) {
  # One match covers the name and the "value" pair that follows it.  Matching the pair
  # together keeps the indices stable, and it is why nothing here needs a start offset:
  # the previous version matched the value with a '^'-anchored pattern at a non-zero
  # offset, which can never succeed, so the JSON was silently never updated.
  $pat = '("name"\s*:\s*"' + [regex]::Escape($Name) + '"\s*,\s*\r?\n\s*"value"\s*:\s*")([^"]*)(")'
  $rx = [regex]::new($pat)
  $hits = $rx.Matches($Text).Count
  if ($hits -eq 0) { return [pscustomobject]@{ Text = $Text; Count = 0; Changed = 0 } }
  $counter = @{ n = 0 }
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    if ($m.Groups[2].Value -eq $Value) { return $m.Value }
    $counter['n'] = $counter['n'] + 1
    return ($m.Groups[1].Value + $Value + $m.Groups[3].Value)
  }
  $out = $rx.Replace($Text, $evaluator)
  return [pscustomobject]@{ Text = $out; Count = $hits; Changed = [int]$counter['n'] }
}

# The stored record arrives in two shapes: the PSCustomObject main.ps1 writes to state.json,
# and the PSCustomObject ConvertFrom-Json rebuilds on a revert run.  Its Sha map comes back
# as a PSCustomObject there, so a plain .ContainsKey()/.Item() read throws on a revert.
function Get-PcbRecField($Rec, [string]$Name) {
  if ($null -eq $Rec) { return $null }
  if ($Rec -is [System.Collections.IDictionary]) {
    if ($Rec.Contains($Name)) { return $Rec[$Name] }
    return $null
  }
  $p = $Rec.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Get-PcbRecKey($Map, [string]$Key) {
  if ($null -eq $Map) { return $null }
  if ($Map -is [System.Collections.IDictionary]) {
    if ($Map.Contains($Key)) { return $Map[$Key] }
    return $null
  }
  $p = $Map.PSObject.Properties[$Key]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Get-PcbLolCfgSha([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return 'error' }
}

function Write-PcbLolText([string]$Path, [string]$Text, [string]$OriginalText) {
  # keep a byte order mark exactly as it was, so a file that did not change stays identical
  $enc = New-Object System.Text.UTF8Encoding($false)
  if ($OriginalText.Length -gt 0 -and $OriginalText[0] -eq [char]0xFEFF) { $enc = New-Object System.Text.UTF8Encoding($true) }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Set-PcbLolCfg {
  param($State, [string]$BackupDir = '')
  $rows = New-Object System.Collections.ArrayList
  $rec = [pscustomobject]@{ Ok = $false; Rows = @(); Backup = $null; Applied = $null; Error = '' }
  try {
    if (Test-PcbLolRunning) {
      [void]$rows.Add([pscustomobject]@{ Item = 'lol/cfg'; Before = 'n/a'; After = 'n/a'; Status = 'SKIP: close the game first' })
      $rec.Ok = $true
      $rec.Rows = @($rows)
      return $rec
    }
    if ($null -eq $State) { $State = Get-PcbLolCfgState }
    if ($null -eq $State -or -not $State.Available) {
      $msg = 'Config dir unavailable'
      if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace([string]$State.Error)) { $msg = [string]$State.Error }
      [void]$rows.Add([pscustomobject]@{ Item = 'lol/cfg'; Before = 'n/a'; After = 'n/a'; Status = ('SKIP: ' + $msg) })
      $rec.Ok = $true
      $rec.Rows = @($rows)
      $rec.Error = $msg
      return $rec
    }
    $dir = [string]$State.Dir
    $sep = [string]$State.Sep
    if ([string]::IsNullOrEmpty($sep)) { $sep = "`r`n" }
    $cfgPath = Join-Path $dir 'game.cfg'
    $perPath = Join-Path $dir 'PersistedSettings.json'

    # backup first: a byte copy is what makes the revert exact
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = Join-Path $StateDir 'lolcfg-backup' }
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $bak = [pscustomobject]@{ Dir = $BackupDir; TargetDir = $dir; Files = @(); Sha = @{} }
    $shaBefore = @{}
    foreach ($f in $script:PcbLolCfgFiles) {
      $src = Join-Path $dir $f
      $shaBefore[$f] = Get-PcbLolCfgSha $src
      if (-not (Test-Path -LiteralPath $src)) { continue }
      Copy-Item -LiteralPath $src -Destination (Join-Path $BackupDir $f) -Force -ErrorAction Stop
      $bak.Files = @($bak.Files) + @($f)
    }
    $bak.Sha = $shaBefore
    $rec.Backup = $bak

    $cfgText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($cfgPath))
    $newCfg = $cfgText
    foreach ($v in $script:PcbLolCfgValues) {
      $newCfg = Set-PcbLolCfgIniValue $newCfg $v.Section $v.Name ([string]$v.Value) $sep
    }
    $perText = ''
    $newPer = ''
    if (Test-Path -LiteralPath $perPath) {
      $perText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($perPath))
      $newPer = $perText
      foreach ($v in $script:PcbLolCfgValues) {
        $r = Set-PcbLolPersistedValue $newPer $v.Name ([string]$v.Value)
        $newPer = [string]$r.Text
      }
    }

    $wrote = [pscustomobject]@{ Cfg = $false; Persisted = $false; Sha = @{} }
    if ($newCfg -ne $cfgText) {
      Write-PcbLolText $cfgPath $newCfg $cfgText
      $wrote.Cfg = $true
    }
    if ($newPer.Length -gt 0 -and $newPer -ne $perText) {
      Write-PcbLolText $perPath $newPer $perText
      $wrote.Persisted = $true
    }
    $wrote.Sha = @{ Cfg = (Get-PcbLolCfgSha $cfgPath); Persisted = (Get-PcbLolCfgSha $perPath) }
    $rec.Applied = $wrote

    # live read-back: re-read game.cfg and report what is on disk now
    $after = Get-PcbLolCfgState -Dir $dir
    $map = @{}
    if ($null -ne $after -and $null -ne $after.Rows) {
      foreach ($r in @($after.Rows)) { $map[[string]$r.Section + '/' + [string]$r.Name] = [string]$r.Before }
    }
    foreach ($v in $script:PcbLolCfgValues) {
      $key = $v.Section + '/' + $v.Name
      $before = '(absent)'
      foreach ($r in @($State.Rows)) { if (([string]$r.Section + '/' + [string]$r.Name) -eq $key) { $before = [string]$r.Before } }
      $now = '(absent)'
      if ($map.ContainsKey($key)) { $now = [string]$map[$key] }
      if ($now -eq [string]$v.Value) {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $key); Before = $before; After = $now; Status = 'OK' })
      } else {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $key); Before = $before; After = $now; Status = 'FAIL: read-back differs' })
      }
    }
    $rec.Ok = $true
    $rec.Rows = @($rows)
  } catch {
    $rec.Ok = $false
    $rec.Error = $_.Exception.Message
    [void]$rows.Add([pscustomobject]@{ Item = 'lol/cfg'; Before = 'unknown'; After = 'unknown'; Status = ('FAIL: ' + $_.Exception.Message) })
    $rec.Rows = @($rows)
  }
  return $rec
}

function Restore-PcbLolCfg {
  param($Rec)
  $rows = New-Object System.Collections.ArrayList
  $out = [pscustomobject]@{ Ok = $false; Rows = @(); Error = '' }
  try {
    $bak = Get-PcbRecField $Rec 'Backup'
    if ($null -eq $Rec -or $null -eq $bak) {
      $out.Error = 'nothing recorded'
      return $out
    }
    $applied = Get-PcbRecField $Rec 'Applied'
    $bakSha = Get-PcbRecField $bak 'Sha'
    $targetDir = [string](Get-PcbRecField $bak 'TargetDir')
    foreach ($f in @(Get-PcbRecField $bak 'Files')) {
      if ($null -eq $f) { continue }
      $src = Join-Path ([string](Get-PcbRecField $bak 'Dir')) ([string]$f)
      if (-not (Test-Path -LiteralPath $src)) {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $f); Before = '(tuned)'; After = 'unknown'; Status = 'SKIP: backup missing' })
        continue
      }
      # only restore a file the kit actually rewrote
      $touched = $false
      if ($null -ne $applied) {
        if ($f -eq 'game.cfg' -and [bool](Get-PcbRecField $applied 'Cfg')) { $touched = $true }
        if ($f -eq 'PersistedSettings.json' -and [bool](Get-PcbRecField $applied 'Persisted')) { $touched = $true }
      }
      if (-not $touched) {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $f); Before = '(untouched)'; After = '(untouched)'; Status = 'SKIP: not written by the kit' })
        continue
      }
      if ([string]::IsNullOrWhiteSpace($targetDir)) {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $f); Before = '(tuned)'; After = 'unknown'; Status = 'FAIL: target dir unknown' })
        continue
      }
      $dstPath = Join-Path $targetDir ([string]$f)
      [System.IO.File]::Copy($src, $dstPath, $true)
      $now = Get-PcbLolCfgSha $dstPath
      $want = 'absent'
      $wantSha = Get-PcbRecKey $bakSha ([string]$f)
      if ($null -ne $wantSha -and -not [string]::IsNullOrWhiteSpace([string]$wantSha)) { $want = [string]$wantSha }
      if ($now -eq $want) {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $f); Before = '(tuned)'; After = 'restored'; Status = 'OK' })
      } else {
        [void]$rows.Add([pscustomobject]@{ Item = ('lol/' + $f); Before = '(tuned)'; After = 'sha differs'; Status = 'FAIL: sha256 mismatch after restore' })
      }
    }
    $out.Ok = $true
    $out.Rows = @($rows)
  } catch {
    $out.Ok = $false
    $out.Error = $_.Exception.Message
  }
  return $out
}

# ==== end lolcfg.ps1 ====


# ---------------------------------------------------------------------------
# PC-bang one-click gaming tweak kit.  Stock Windows PowerShell 5.1, ASCII only.
# ---------------------------------------------------------------------------

$script:PcbNewScheme = 'a5f0c0de-1a7e-4c0a-9b1e-00000000a001'
$script:PcbSchemeNames = @('e9a42b02-d5df-448d-aa00-03f14749eb61','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
$script:SubProcessor = '54533251-82be-4824-96c1-47b60b740d00'
$script:SubUsb = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:PcbRows = New-Object System.Collections.ArrayList
$script:PcbState = @{}
$script:PcbStateDirty = $false
$script:PcbSelfPath = $null
# DirectX user preferences target; -DxPrefsPath/-DxPrefsName let a test drive a
# throw-away key instead of the real HKCU\Software\Microsoft\DirectX one.
$script:PcbDxPath = $DxPrefsPath
$script:PcbDxName = $DxPrefsName

# ===========================================================================
# generic helpers
# ===========================================================================

function Write-PcbLine([string]$text) {
  # straight to stdout so Invoke-PcbMain's return value stays the exit code.
  # multi-line text is written line by line: folding CR/LF to '?' would collapse the
  # whole report table into one row.  the 7-bit folding still applies per line.
  if ($null -eq $text) { $text = '' }
  $body = [regex]::Replace($text, '(\r\n|\n|\r)$', '')
  foreach ($ln in [regex]::Split($body, '\r\n|\n|\r')) {
    $safe = [regex]::Replace($ln, '[^\x20-\x7E]', '?')
    [Console]::Out.WriteLine($safe)
  }
}

function Save-PcbState {
  if ($script:PcbDryRun) { return }
  try {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $json = $script:PcbState | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'state.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Write-PcbLine ("state save failed: " + $_.Exception.Message)
  }
}

function Add-PcbRow {
  param([string]$Step, [string]$Item, $Before, $After, [string]$Status)
  $row = [pscustomobject]@{ Step = $Step; Item = $Item; Before = $Before; After = $After; Status = $Status }
  [void]$script:PcbRows.Add($row)
  return $row
}

# A revert reloads state.json through ConvertFrom-Json, so every stored record comes back
# as a PSCustomObject instead of the hashtable the apply run built.  A .ContainsKey() or
# ['x'] read on such a record is a non-terminating error: the whole restore function dies
# where it stands and the row it should have printed never appears.  This reader answers
# for both shapes, the same contract as Get-PcbRecField in src\lolcfg.ps1.
function Get-PcbStateField($Rec, [string]$Name) {
  if ($null -eq $Rec) { return $null }
  if ($Rec -is [System.Collections.IDictionary]) {
    if ($Rec.Contains($Name)) { return $Rec[$Name] }
    return $null
  }
  $p = $Rec.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Get-PcbActiveGuid {
  try {
    $txt = (@(powercfg /getactivescheme 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    $m = [regex]::Match($txt, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value.ToLower() }
  } catch { }
  return $null
}

function Get-PcbSchemeList {
  try {
    $txt = (@(powercfg /list 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    return @([regex]::Matches($txt, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLower() })
  } catch { return @() }
}

# ===========================================================================
# native interop
# ===========================================================================

$script:PcbNativeCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PcbNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        [MarshalAs(UnmanagedType.U4)] public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        [MarshalAs(UnmanagedType.U4)] public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency,
                   dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2,
                   dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevicesW(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsExW(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, ref int pvParam, uint fWinIni);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetLogicalProcessorInformationEx(int relationshipType, IntPtr buffer, ref uint returnedLength);

    public static string[] DisplayDevices()
    {
        List<string> o = new List<string>();
        DISPLAY_DEVICE d = new DISPLAY_DEVICE();
        d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevicesW(null, i, ref d, 0); i++)
        {
            o.Add(d.DeviceName + "|" + d.DeviceString + "|" + d.StateFlags);
            d = new DISPLAY_DEVICE();
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return o.ToArray();
    }

    public static string CurrentMode(string dev)
    {
        DEVMODE d = new DEVMODE();
        d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsW(dev, -1, ref d)) { return null; }
        return d.dmPelsWidth + "|" + d.dmPelsHeight + "|" + d.dmBitsPerPel + "|" + d.dmDisplayFrequency;
    }

    public static string[] AllModes(string dev)
    {
        List<string> o = new List<string>();
        for (int i = 0; i < 4096; i++)
        {
            DEVMODE d = new DEVMODE();
            d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsW(dev, i, ref d)) { break; }
            o.Add(d.dmPelsWidth + "|" + d.dmPelsHeight + "|" + d.dmBitsPerPel + "|" + d.dmDisplayFrequency);
        }
        return o.ToArray();
    }

    public static int SetMode(string dev, int w, int h, int bpp, int hz)
    {
        DEVMODE d = new DEVMODE();
        d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        d.dmFields = 0x00080000 | 0x00100000 | 0x00040000 | 0x00400000;
        d.dmPelsWidth = w;
        d.dmPelsHeight = h;
        d.dmBitsPerPel = bpp;
        d.dmDisplayFrequency = hz;
        return ChangeDisplaySettingsExW(dev, ref d, IntPtr.Zero, 0x1, IntPtr.Zero);
    }

    public static int[] GetMouseAccel()
    {
        int[] v = new int[3];
        if (!SystemParametersInfoW(0x0003, 0, v, 0)) { return null; }
        return v;
    }

    public static bool SetMouseAccel(int a, int b, int c)
    {
        int[] v = new int[] { a, b, c };
        return SystemParametersInfoW(0x0004, 0, v, 0x3);
    }

    public static int GetMouseSpeed()
    {
        int v = 0;
        if (!SystemParametersInfoW(0x0070, 0, ref v, 0)) { return -1; }
        return v;
    }

    public static bool SetMouseSpeed(int s)
    {
        int v = s;
        return SystemParametersInfoW(0x0071, 0, ref v, 0x3);
    }

    public static string[] CoreRelations()
    {
        List<string> o = new List<string>();
        // GetLogicalProcessorInformationEx only ever returns the ONE relationship type it
        // was asked for: type 0 is RelationProcessorCore, type 2 is RelationCache.  The
        // first call must therefore be made per type, or the cache records simply never
        // show up.
        Collect(o, 0);
        Collect(o, 2);
        return o.ToArray();
    }

    private static void Collect(List<string> o, int relation)
    {
        uint len = 0;
        GetLogicalProcessorInformationEx(relation, IntPtr.Zero, ref len);
        if (len == 0) { return; }
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try
        {
            if (!GetLogicalProcessorInformationEx(relation, buf, ref len)) { return; }
            int off = 0;
            while (off + 8 <= (int)len)
            {
                IntPtr p = (IntPtr)((long)buf + off);
                int rel = Marshal.ReadInt32(p, 0);
                int size = Marshal.ReadInt32(p, 4);
                if (size <= 0) { break; }
                if (rel == 0 && size >= 40)
                {
                    byte cls = Marshal.ReadByte(p, 8 + 1);
                    int gc = Marshal.ReadInt16(p, 8 + 22) & 0xFFFF;
                    for (int g = 0; g < gc; g++)
                    {
                        int baseOff = 8 + 24 + g * 16;
                        if (baseOff + 10 > size) { break; }
                        long mask = Marshal.ReadInt64(p, baseOff);
                        int grp = Marshal.ReadInt16(p, baseOff + 8) & 0xFFFF;
                        o.Add(cls + "|" + mask + "|" + grp);
                    }
                }
                // RelationCache == 2.  CACHE_RELATIONSHIP (winnt.h, um/winnt.h in the
                // 10.0.26100.0 SDK): Level BYTE @0, Associativity BYTE @1, LineSize WORD
                // @2, CacheSize DWORD @4, Type (4-byte enum) @8, Reserved[18] @12,
                // GroupCount WORD @30, union GroupMask @32 (GROUP_AFFINITY: Mask 8 bytes,
                // Group WORD).  The record header is 8 bytes, so add 8 to every offset.
                if (rel == 2 && size >= 56)
                {
                    int lvl = Marshal.ReadByte(p, 8 + 0);
                    int csize = Marshal.ReadInt32(p, 8 + 4);
                    int gc = Marshal.ReadInt16(p, 8 + 30) & 0xFFFF;
                    for (int g = 0; g < gc; g++)
                    {
                        int baseOff = 8 + 32 + g * 16;
                        if (baseOff + 10 > size) { break; }
                        long mask = Marshal.ReadInt64(p, baseOff);
                        int grp = Marshal.ReadInt16(p, baseOff + 8) & 0xFFFF;
                        o.Add("L|" + lvl + "|" + mask + "|" + grp + "|" + csize);
                    }
                }
                off += size;
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

function Initialize-PcbNative {
  if (-not ([System.Management.Automation.PSTypeName]'PcbNative').Type) {
    Add-Type -TypeDefinition $script:PcbNativeCode -Language CSharp -ErrorAction Stop
  }
}

# ===========================================================================
# CPU masks
# ===========================================================================

function Get-PcbCoreList {
  Initialize-PcbNative
  $res = [PcbNative]::CoreRelations()
  $list = New-Object System.Collections.ArrayList
  foreach ($line in @($res)) {
    $p = ([string]$line).Split('|')
    if ($p.Count -lt 3) { continue }
    if ([int]$p[2] -ne 0) { continue }   # group 0 only
    [void]$list.Add([pscustomobject]@{ Class = [int]$p[0]; Mask = [uint64]$p[1] })
  }
  return @($list)
}

# L3 caches of group 0: @([pscustomobject]@{ Mask = <uint64>; Size = <bytes> })
# Cache records are tagged 'L|<level>|<mask>|<group>|<size>' by PcbNative.CoreRelations.
function Get-PcbL3List {
  Initialize-PcbNative
  $res = [PcbNative]::CoreRelations()
  $list = New-Object System.Collections.ArrayList
  foreach ($line in @($res)) {
    $p = ([string]$line).Split('|')
    if ($p.Count -lt 5) { continue }
    if ($p[0] -ne 'L') { continue }
    if ([int]$p[1] -ne 3) { continue }
    if ([int]$p[3] -ne 0) { continue }   # group 0 only
    [void]$list.Add([pscustomobject]@{ Mask = [uint64]$p[2]; Size = [int]$p[4] })
  }
  return @($list)
}

function Get-PcbMasks {
  param([object[]]$Cores, [object[]]$L3)
  $injected = $PSBoundParameters.ContainsKey('Cores') -and ($null -ne $Cores)
  if (-not $injected) { $Cores = @(Get-PcbCoreList) }
  $l3Given = $PSBoundParameters.ContainsKey('L3') -and ($null -ne $L3)
  $game = [uint64]0
  $side = [uint64]0
  $irq = [uint64]0
  if ($Cores.Count -eq 0) {
    return [pscustomobject]@{ GameMask = $game; SideMask = $side; IrqMask = $irq }
  }
  $pclass = 0
  foreach ($c in $Cores) { if ([int]$c.Class -gt $pclass) { $pclass = [int]$c.Class } }
  $P = @($Cores | Where-Object { [int]$_.Class -eq $pclass })
  $E = @($Cores | Where-Object { [int]$_.Class -ne $pclass })
  $orP = [uint64]0
  foreach ($c in $P) { $orP = $orP -bor [uint64]$c.Mask }
  if ($E.Count -gt 0) {
    $eOr = [uint64]0
    foreach ($c in $E) { $eOr = $eOr -bor [uint64]$c.Mask }
    $side = $eOr
  } else {
    $side = [uint64]$P[0].Mask
  }

  # X3D split: on a 3D V-Cache part the large L3 sits on one CCD and the small L3 on
  # the other, so the masks have to follow the cache instead of "everything but cpu 0".
  # Only when the L3 story is unambiguous: >= 2 distinct masks and >= 2 distinct sizes.
  $l3Use = $null
  if ($P.Count -ge 6) {
    if (-not $l3Given) {
      try { $L3 = @(Get-PcbL3List) } catch { $L3 = @() }
    }
    $l3All = @($L3)
    $masks = @{}
    $sizes = @{}
    foreach ($e in $l3All) {
      if ($null -eq $e) { continue }
      $mm = [uint64]$e.Mask
      if ($mm -eq 0) { continue }
      $masks[[string]$mm] = 1
      $sizes[[string]([int]$e.Size)] = 1
    }
    if ($masks.Count -ge 2 -and $sizes.Count -ge 2) {
      $best = $null
      foreach ($e in $l3All) {
        if ($null -eq $e) { continue }
        if ($null -eq $best -or [int]$e.Size -gt [int]$best.Size) { $best = $e }
      }
      if ($null -ne $best) { $l3Use = [uint64]$best.Mask }
    }
  }

  if ($P.Count -ge 6) {
    # Non-SMT: one bit per physical core, so P[0].Mask alone is a SINGLE logical CPU and
    # mouse + GPU + NIC would all share it.  Hand the interrupt set P[0] and P[1] (two
    # physical cores) and keep the game off both.  An SMT CPU's P[0].Mask already has
    # both siblings, so this branch never fires there and the numbers stay as today.
    $irq = [uint64]$P[0].Mask
    $irqExtra = [uint64]0
    $bits = 0
    for ($i = 0; $i -lt 64; $i++) {
      if (($irq -band ([uint64]1 -shl $i)) -ne [uint64]0) { $bits++ }
    }
    if ($bits -eq 1 -and $P.Count -ge 2) { $irqExtra = [uint64]$P[1].Mask }
    if ($null -ne $l3Use) {
      $game = ($orP -band [uint64]$l3Use) -band (-bnot [uint64]$P[0].Mask)
      $side = $orP -band (-bnot [uint64]$l3Use)
    } else {
      $game = $orP -band (-bnot [uint64]$P[0].Mask)
    }
    if ($irqExtra -ne [uint64]0) {
      $irq = $irq -bor $irqExtra
      $game = $game -band (-bnot $irqExtra)
    }
  } else {
    $game = $orP
    $irq = [uint64]0
  }
  return [pscustomobject]@{ GameMask = $game; SideMask = $side; IrqMask = $irq }
}

function Format-PcbMask([uint64]$m) { return ('0x{0:X}' -f $m) }

# ===========================================================================
# step a - power
# ===========================================================================

function Get-PcbPowerValue([string]$Scheme, [string]$Sub, [string]$Setting) {
  $txt = (@(powercfg /query $Scheme $Sub $Setting 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
  $ac = $null
  $dc = $null
  $m = [regex]::Match($txt, '(?m)^[^\r\n]*\bAC\b[^\r\n]*?(0x[0-9A-Fa-f]{1,8})')
  if ($m.Success) { $ac = [Convert]::ToInt32($m.Groups[1].Value.Substring(2), 16) }
  $m = [regex]::Match($txt, '(?m)^[^\r\n]*\bDC\b[^\r\n]*?(0x[0-9A-Fa-f]{1,8})')
  if ($m.Success) { $dc = [Convert]::ToInt32($m.Groups[1].Value.Substring(2), 16) }
  return [pscustomobject]@{ AC = $ac; DC = $dc }
}

function Invoke-PcbPowerSet([string]$Scheme, [string]$Sub, [string]$Setting, [int]$Value) {
  & powercfg /setacvalueindex $Scheme $Sub $Setting $Value 2>&1 | Out-Null
  $rcA = $LASTEXITCODE
  & powercfg /setdcvalueindex $Scheme $Sub $Setting $Value 2>&1 | Out-Null
  $rcD = $LASTEXITCODE
  if ($rcA -ne 0) {
    & powercfg -attributes $Sub $Setting -ATTRIB_HIDE 2>&1 | Out-Null
    & powercfg /setacvalueindex $Scheme $Sub $Setting $Value 2>&1 | Out-Null
    $rcA = $LASTEXITCODE
  }
  return [pscustomobject]@{ AC = $rcA; DC = $rcD }
}

# A hidden power setting prints only its scheme header, so 'no AC line' is how the kit
# tells 'hidden' from 'not on this PC' (an unknown GUID fails outright).
function Test-PcbPowerVisible([string]$Scheme, [string]$Sub, [string]$Setting) {
  $txt = (@(powercfg /query $Scheme $Sub $Setting 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
  return [bool]($txt -match '(?m)^[^\r\n]*\bAC\b')
}

# ===========================================================================
# IDLEDISABLE boost guard
# ===========================================================================
#
# IDLEDISABLE=1 keeps the cores out of the idle state, which is what the home PC runs.
# On an Intel part whose turbo bin depends on the number of active cores it can also
# lower the single-core ceiling, so the kit measures instead of assuming: spin a thread
# pinned to the first game CPU for 400 ms with the value at 0 and again at 1, keep 1
# only when it costs less than 2 %.  $script:PcbSpeedProbe is a scriptblock returning a
# positive integer (the iteration count) so a test can inject a fixed pair.

$script:PcbSpeedProbe = $null

$script:PcbSpeedCode = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class PcbSpeed {
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentThread();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern UIntPtr SetThreadAffinityMask(IntPtr hThread, UIntPtr dwThreadAffinityMask);

    // Pure integer/FP arithmetic: a core that is boosting finishes more work per 400 ms.
    public static long Spin(int ms, ulong mask) {
        IntPtr h = GetCurrentThread();
        UIntPtr old = UIntPtr.Zero;
        if (mask != 0) {
            try { old = SetThreadAffinityMask(h, new UIntPtr(mask)); } catch { old = UIntPtr.Zero; }
        }
        try {
            Stopwatch sw = Stopwatch.StartNew();
            long n = 0;
            double acc = 0.0;
            while (sw.ElapsedMilliseconds < ms) {
                for (int i = 0; i < 2000; i++) {
                    acc += Math.Sqrt((double)(n + i)) + (acc * 0.5);
                }
                n += 2000;
            }
            if (acc < 0.0) { return -1; }
            return n;
        } finally {
            if (mask != 0 && old != UIntPtr.Zero) {
                try { SetThreadAffinityMask(h, old); } catch { }
            }
        }
    }
}
'@

function Get-PcbFirstCpu([uint64]$Mask) {
  for ($i = 0; $i -lt 64; $i++) {
    if ((($Mask -shr $i) -band 1) -ne 0) { return $i }
  }
  return 0
}

function Invoke-PcbSpeedSpin([uint64]$Mask) {
  if (-not ([System.Management.Automation.PSTypeName]'PcbSpeed').Type) {
    Add-Type -TypeDefinition $script:PcbSpeedCode -Language CSharp -ErrorAction Stop
  }
  $m = $Mask
  if ($m -eq 0) { $m = [uint64]1 }
  return [long][PcbSpeed]::Spin(400, $m)
}

# Best of three: a single spin is noisy enough to flip a 2 % decision.
function Measure-PcbSpeed([uint64]$Mask) {
  if ($null -ne $script:PcbSpeedProbe) {
    $v = & $script:PcbSpeedProbe
    $n = 0
    if ([int]::TryParse([string]$v, [ref]$n)) { return $n }
    return 0
  }
  $best = [long]0
  for ($i = 0; $i -lt 3; $i++) {
    $v = Invoke-PcbSpeedSpin $Mask
    if ($v -gt $best) { $best = $v }
  }
  return $best
}

function Solve-PcbIdleDisable([uint64]$Mask, [string]$Scheme) {
  # Returns @{ Want; Speed0; Speed1; Decision }.  A zero measurement on either side
  # means the probe could not run, and then the home value (1) is kept.
  #
  # The guard activates $Scheme to make each write take effect.  It is a throw-away
  # scheme in tests and a freshly duplicated one in production, so leaving it active
  # when the function exits early or throws would leave the PC on a scheme that is
  # about to be deleted.  Whatever was active on entry is put back in the finally.
  $rec = @{ Want = 1; Speed0 = 0; Speed1 = 0; Decision = '' }
  $prev = Get-PcbActiveGuid
  try {
    Invoke-PcbPowerSet $Scheme $script:SubProcessor 'IDLEDISABLE' 0 | Out-Null
    & powercfg /setactive $Scheme 2>&1 | Out-Null
    $rec.Speed0 = Measure-PcbSpeed $Mask
    Invoke-PcbPowerSet $Scheme $script:SubProcessor 'IDLEDISABLE' 1 | Out-Null
    & powercfg /setactive $Scheme 2>&1 | Out-Null
    $rec.Speed1 = Measure-PcbSpeed $Mask
    if ($rec.Speed0 -le 0 -or $rec.Speed1 -le 0) {
      $rec.Want = 1
      $rec.Decision = 'probe failed, keeping 1'
    } elseif ($rec.Speed1 -ge ($rec.Speed0 * 0.98)) {
      $rec.Want = 1
      $rec.Decision = 'kept 1'
    } else {
      $rec.Want = 0
      $rec.Decision = 'dropped to 0 (boost loss)'
    }
  } catch {
    $rec.Want = 1
    $rec.Decision = 'probe error, keeping 1'
  } finally {
    # only touch the active scheme when the guard actually moved it, and never when
    # $prev was unreadable - then leaving $Scheme active is the caller's problem.
    if ($prev -and $prev -ne 'none') {
      $now = Get-PcbActiveGuid
      if ($now -ne $prev) { & powercfg /setactive $prev 2>&1 | Out-Null }
    }
  }
  return $rec
}

function Get-PcbSchemeCandidates {
  # Ultimate Performance is often not listed on this PC (it ships as a template only).
  # -duplicatescheme still accepts the template GUID, so listing is not a gate.
  if ($null -ne $SchemeCandidates -and @($SchemeCandidates).Count -gt 0) {
    # 'a,b' arrives as one element when the kit is launched with -File, so split it.
    $out = New-Object System.Collections.ArrayList
    foreach ($s in @($SchemeCandidates)) {
      foreach ($part in ([string]$s).Split(',')) {
        $p = $part.Trim()
        if ($p.Length -gt 0) { [void]$out.Add($p) }
      }
    }
    return @($out)
  }
  return @($script:PcbSchemeNames)
}

function Invoke-PcbStepPower {
  param($Masks = $null)
  $before = Get-PcbActiveGuid
  $script:PcbState['Power'] = @{ BeforeGuid = $before; NewGuid = $script:PcbNewScheme }
  Save-PcbState
  if ($script:PcbDryRun) {
    Add-PcbRow 'a' 'power/scheme' $before $before 'DRYRUN' | Out-Null
    foreach ($s in $script:PcbPowerSettings) {
      Add-PcbRow 'a' ('power/' + $s.Item) ('AC=' + $s.Want + '/DC=' + $s.Want) ('AC=' + $s.Want + '/DC=' + $s.Want) 'DRYRUN' | Out-Null
    }
    if ($script:PcbIdleDisableGuard) {
      Add-PcbRow 'a' 'power/IDLEDISABLE-guard' 'wanted=1' 'measure 0 vs 1' 'DRYRUN' | Out-Null
    }
    return
  }
  $src = $null
  $listed = @(Get-PcbSchemeList)
  $cands = @(Get-PcbSchemeCandidates)
  $tried = @{}
  $tries = New-Object System.Collections.ArrayList
  foreach ($cand in $cands) {
    if ([string]::IsNullOrWhiteSpace([string]$cand)) { continue }
    $c = ([string]$cand).ToLower()
    if ($tried.ContainsKey($c)) { continue }
    $tried[$c] = 1
    [void]$tries.Add($c)
    & powercfg -delete $script:PcbNewScheme 2>&1 | Out-Null
    & powercfg -duplicatescheme $c $script:PcbNewScheme 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and @(Get-PcbSchemeList) -contains $script:PcbNewScheme) { $src = $c; break }
  }
  if ($null -eq $src -and $before -and -not $tried.ContainsKey($before)) {
    [void]$tries.Add($before)
    & powercfg -delete $script:PcbNewScheme 2>&1 | Out-Null
    & powercfg -duplicatescheme $before $script:PcbNewScheme 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and @(Get-PcbSchemeList) -contains $script:PcbNewScheme) { $src = $before }
  }
  if ($null -eq $src) {
    Add-PcbRow 'a' 'power/scheme' $before 'n/a' 'FAIL: no source scheme could be duplicated' | Out-Null
    return
  }
  $srcNote = $src
  if ($listed -notcontains $src) { $srcNote = $src + ' (not listed)' }
  & powercfg -changename $script:PcbNewScheme 'PCBang Gaming' 2>&1 | Out-Null
  $unhidden = New-Object System.Collections.ArrayList
  $guardNote = ''
  foreach ($s in $script:PcbPowerSettings) {
    $cleared = $false
    if ($s.ContainsKey('Unhide') -and [int]$s.Unhide -eq 1) {
      # A hidden setting answers only its scheme header, so the kit clears the hide
      # attribute, writes, and puts the attribute back on revert.
      if (-not (Test-PcbPowerVisible $script:PcbNewScheme $s.Sub $s.Id)) {
        & powercfg -attributes $s.Sub $s.Id -ATTRIB_HIDE 2>&1 | Out-Null
        Start-Sleep -Milliseconds 150
        if (Test-PcbPowerVisible $script:PcbNewScheme $s.Sub $s.Id) {
          $cleared = $true
          [void]$unhidden.Add(@{ Sub = [string]$s.Sub; Id = [string]$s.Id })
        }
      }
    }
    $pre = Get-PcbPowerValue $script:PcbNewScheme $s.Sub $s.Id
    if ($null -eq $pre.AC -and $null -eq $pre.DC) {
      Add-PcbRow 'a' ('power/' + $s.Item) 'absent' 'absent' 'SKIP: not supported here' | Out-Null
      continue
    }
    $want = [int]$s.Want
    if ($s.Item -eq 'IDLEDISABLE' -and $script:PcbIdleDisableGuard) {
      $m = $Masks
      if ($null -eq $m) { try { $m = Get-PcbMasks } catch { $m = $null } }
      $cpuMask = [uint64]1
      if ($null -ne $m) { $cpuMask = [uint64]$m.GameMask }
      $g = Solve-PcbIdleDisable $cpuMask $script:PcbNewScheme
      $want = [int]$g.Want
      $guardNote = ('0=' + $g.Speed0 + ' 1=' + $g.Speed1 + ', ' + $g.Decision)
      $pre = Get-PcbPowerValue $script:PcbNewScheme $s.Sub $s.Id
    }
    $rc = Invoke-PcbPowerSet $script:PcbNewScheme $s.Sub $s.Id $want
    $post = Get-PcbPowerValue $script:PcbNewScheme $s.Sub $s.Id
    $fmt = 'AC=' + $post.AC + '/DC=' + $post.DC
    $bTxt = 'AC=' + $pre.AC + '/DC=' + $pre.DC
    if ($cleared) { $bTxt = $bTxt + ' (hidden)' }
    # a value the firmware will not read back is a SKIP, not a failure
    if ($post.AC -eq $want -and ($post.DC -eq $want -or $null -eq $post.DC)) {
      if ($s.Item -eq 'IDLEDISABLE' -and $guardNote.Length -gt 0) {
        Add-PcbRow 'a' ('power/' + $s.Item) $bTxt $fmt ('OK (' + $guardNote + ')') | Out-Null
      } else {
        Add-PcbRow 'a' ('power/' + $s.Item) $bTxt $fmt 'OK' | Out-Null
      }
    } elseif ($rc.AC -ne 0 -or $post.AC -ne $want) {
      if ($rc.AC -ne 0) {
        Add-PcbRow 'a' ('power/' + $s.Item) $bTxt $fmt 'SKIP: not supported here' | Out-Null
      } else {
        Add-PcbRow 'a' ('power/' + $s.Item) $bTxt $fmt ('FAIL: read-back differs (rc ' + $rc.AC + '/' + $rc.DC + ')') | Out-Null
      }
    } else {
      Add-PcbRow 'a' ('power/' + $s.Item) $bTxt $fmt 'OK' | Out-Null
    }
  }
  $script:PcbState['Power'] = @{ BeforeGuid = $before; NewGuid = $script:PcbNewScheme; Unhidden = @($unhidden) }
  Save-PcbState
  & powercfg /setactive $script:PcbNewScheme 2>&1 | Out-Null
  $after = Get-PcbActiveGuid
  if ($after -eq $script:PcbNewScheme) {
    Add-PcbRow 'a' 'power/scheme' $before $after ('OK (source ' + $srcNote + ')') | Out-Null
  } else {
    Add-PcbRow 'a' 'power/scheme' $before $after 'FAIL: setactive did not stick' | Out-Null
  }
}

function Restore-PcbPower {
  if ($script:PcbDryRun) { return }
  $p = $script:PcbState['Power']
  if ($null -eq $p) { return }
  $before = $p.BeforeGuid
  $new = $p.NewGuid
  $cur = Get-PcbActiveGuid
  $lst = @(Get-PcbSchemeList)
  if ($before -and ($lst -contains $before) -and $cur -ne $before) {
    & powercfg /setactive $before 2>&1 | Out-Null
  }
  if ($new -and (@(Get-PcbSchemeList) -contains $new)) {
    $cur2 = Get-PcbActiveGuid
    if ($cur2 -eq $new -and $before) { & powercfg /setactive $before 2>&1 | Out-Null }
    & powercfg -delete $new 2>&1 | Out-Null
  }
  # put back the hide attribute on every setting the kit had to unhide
  foreach ($u in @($p.Unhidden)) {
    if ($null -eq $u) { continue }
    try {
      & powercfg -attributes ([string]$u.Sub) ([string]$u.Id) +ATTRIB_HIDE 2>&1 | Out-Null
    } catch { }
  }
  Add-PcbRow 'r' 'power/scheme' $cur (Get-PcbActiveGuid) 'OK' | Out-Null
}

# ===========================================================================
# step b - display
# ===========================================================================

function Get-PcbDisplays {
  Initialize-PcbNative
  $out = New-Object System.Collections.ArrayList
  foreach ($line in @([PcbNative]::DisplayDevices())) {
    $p = ([string]$line).Split('|')
    if ($p.Count -lt 3) { continue }
    $flags = 0
    [void][int]::TryParse($p[2], [ref]$flags)
    if (($flags -band 0x1) -eq 0) { continue }
    [void]$out.Add([pscustomobject]@{ Device = $p[0]; Name = $p[1]; Flags = $flags })
  }
  return @($out)
}

function Get-PcbDisplayHz([string]$dev) {
  Initialize-PcbNative
  $cur = [PcbNative]::CurrentMode($dev)
  if ($null -eq $cur) { return $null }
  $p = ([string]$cur).Split('|')
  return [pscustomobject]@{ W = [int]$p[0]; H = [int]$p[1]; Bpp = [int]$p[2]; Hz = [int]$p[3] }
}

function Get-PcbMaxHz([string]$dev, [int]$w, [int]$h, [int]$bpp) {
  Initialize-PcbNative
  $best = 0
  foreach ($line in @([PcbNative]::AllModes($dev))) {
    $p = ([string]$line).Split('|')
    if ($p.Count -lt 4) { continue }
    if ([int]$p[0] -ne $w -or [int]$p[1] -ne $h -or [int]$p[2] -ne $bpp) { continue }
    if ([int]$p[3] -gt $best) { $best = [int]$p[3] }
  }
  return $best
}

function Invoke-PcbStepDisplay {
  if ($NoDisplay) {
    Add-PcbRow 'b' 'display' 'n/a' 'n/a' 'SKIP: -NoDisplay' | Out-Null
    return
  }
  $recs = New-Object System.Collections.ArrayList
  foreach ($d in @(Get-PcbDisplays)) {
    $cur = Get-PcbDisplayHz $d.Device
    if ($null -eq $cur) {
      Add-PcbRow 'b' ('display/' + $d.Device) 'unknown' 'unknown' 'SKIP: current mode not readable' | Out-Null
      continue
    }
    $rec = @{ Device = $d.Device; OldW = $cur.W; OldH = $cur.H; OldBpp = $cur.Bpp; OldHz = $cur.Hz; NewHz = $cur.Hz }
    [void]$recs.Add($rec)
    $max = Get-PcbMaxHz $d.Device $cur.W $cur.H $cur.Bpp
    if ($max -le $cur.Hz) {
      Add-PcbRow 'b' ('display/' + $d.Device) ($cur.Hz.ToString() + ' Hz') ($cur.Hz.ToString() + ' Hz') 'SKIP: already at max refresh' | Out-Null
      continue
    }
    if ($script:PcbDryRun) {
      Add-PcbRow 'b' ('display/' + $d.Device) ($cur.Hz.ToString() + ' Hz') ($max.ToString() + ' Hz') 'DRYRUN' | Out-Null
      continue
    }
    $rc = [PcbNative]::SetMode($d.Device, $cur.W, $cur.H, $cur.Bpp, $max)
    $post = Get-PcbDisplayHz $d.Device
    if ($rc -eq 0 -and $null -ne $post) {
      $rec.NewHz = $post.Hz
      Add-PcbRow 'b' ('display/' + $d.Device) ($cur.Hz.ToString() + ' Hz') ($post.Hz.ToString() + ' Hz') 'OK' | Out-Null
    } else {
      Add-PcbRow 'b' ('display/' + $d.Device) ($cur.Hz.ToString() + ' Hz') ('rc=' + $rc) ('FAIL: ChangeDisplaySettingsEx rc ' + $rc) | Out-Null
    }
  }
  $script:PcbState['Display'] = @($recs)
  Save-PcbState
}

function Restore-PcbDisplay {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['Display']
  if ($null -eq $recs) { return }
  foreach ($r in @($recs)) {
    $cur = Get-PcbDisplayHz $r.Device
    if ($null -eq $cur) { continue }
    if ($cur.Hz -eq [int]$r.OldHz) {
      Add-PcbRow 'r' ('display/' + $r.Device) ($cur.Hz.ToString() + ' Hz') ($cur.Hz.ToString() + ' Hz') 'SKIP: already original' | Out-Null
      continue
    }
    $rc = [PcbNative]::SetMode($r.Device, [int]$r.OldW, [int]$r.OldH, [int]$r.OldBpp, [int]$r.OldHz)
    $post = Get-PcbDisplayHz $r.Device
    $hz = 'n/a'
    if ($null -ne $post) { $hz = $post.Hz.ToString() + ' Hz' }
    if ($rc -eq 0) {
      Add-PcbRow 'r' ('display/' + $r.Device) ($cur.Hz.ToString() + ' Hz') $hz 'OK' | Out-Null
    } else {
      Add-PcbRow 'r' ('display/' + $r.Device) ($cur.Hz.ToString() + ' Hz') $hz ('FAIL: rc ' + $rc) | Out-Null
    }
  }
}

# ===========================================================================
# step c - NIC
# ===========================================================================

$script:PcbNicKeywords = @(
  '*InterruptModeration=0',
  '*EEE=0',
  '*FlowControl=0',
  'EEELinkAdvertisement=0',
  'AdvancedEEE=0',
  'EnableGreenEthernet=0',
  'GigaLite=0',
  'PowerSavingMode=0',
  'EnableConnectedPowerGating=0',
  '*LsoV2IPv4=0',
  '*LsoV2IPv6=0',
  '*RscIPv4=0',
  '*RscIPv6=0',
  '*RSS=1',
  '*NumRssQueues=4'
)

# The four bindings disabled on the home PC (p60.ps1:3, p61.ps1:3 and the W-INV2
# re-sweep).  The QoS scheduler, NPCAP and the two Microsoft virtual drivers cost
# per-packet work even when they see no match.
$script:PcbNicBindings = @('ms_pacer', 'INSECURE_NPCAP', 'ms_l2bridge', 'ms_l1vhlwf')

# netsh writes: only the ones that are live on the home PC (W-INV2: initialRto=300 holds,
# the ctcp supplemental write did not - live provider is bbr2, so it is not shipped).
# rsc is still listed because `netsh int tcp show global` at home reports it disabled.
$script:PcbNetshCommands = @(
  'int tcp set global rsc=disabled',
  'int tcp set global initialRto=300'
)

# Injectable seams: a test replaces these so no real adapter is touched.
$script:PcbNicAdapters = $null       # scriptblock -> adapter objects (Name, ...)
$script:PcbNicPropGet = $null        # scriptblock (Name, Keyword) -> advanced property or $null
$script:PcbNicPropSet = $null        # scriptblock (Name, Keyword, Value) -> $null
$script:PcbNicBindGet = $null        # scriptblock (Name) -> binding records
$script:PcbNicBindSet = $null        # scriptblock (Name, ComponentId, Enabled) -> $null
$script:PcbNetshRun = $null          # scriptblock (ArgumentArray) -> @{ Output; Code }
$script:PcbNicRestart = $null        # scriptblock (Name) -> $null
$script:PcbQosAdd = $null            # scriptblock (Name) -> $null (throws on failure)
$script:PcbQosGet = $null            # scriptblock (Name) -> policy object or $null
$script:PcbQosRemove = $null         # scriptblock (Name) -> $null

function Invoke-PcbNetsh([string[]]$Arguments) {
  if ($null -ne $script:PcbNetshRun) {
    $r = & $script:PcbNetshRun $Arguments
    $out = ''
    $code = 0
    if ($null -ne $r) {
      if ($r -is [hashtable] -or $r.PSObject.Properties['Output']) {
        $out = [string]$r.Output
        if ($null -ne $r.Code) { $code = [int]$r.Code }
      } else { $out = [string]$r }
    }
    return [pscustomobject]@{ Output = $out; Code = $code }
  }
  $txt = ''
  try {
    $txt = (@(& netsh @Arguments 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    $rc = $LASTEXITCODE
  } catch {
    return [pscustomobject]@{ Output = $_.Exception.Message; Code = -1 }
  }
  return [pscustomobject]@{ Output = $txt; Code = [int]$rc }
}

# 'Initial RTO                 : 300' -> @{ 'Initial RTO' = '300' }.  The labels are
# localized on a Korean Windows, so the map is keyed by the label text as printed and the
# before/after snapshots are compared as whole maps.
function ConvertFrom-PcbNetshShow([string]$Text) {
  $map = @{}
  foreach ($ln in ([string]$Text).Split("`n")) {
    $t = $ln.Trim()
    if ($t.Length -eq 0) { continue }
    $i = $t.IndexOf(':')
    if ($i -le 0) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    if ($k.Length -eq 0) { continue }
    $map[$k] = $v
  }
  return $map
}

function Get-PcbNetshSnapshot {
  $g = Invoke-PcbNetsh @('int', 'tcp', 'show', 'global')
  $s = Invoke-PcbNetsh @('int', 'tcp', 'show', 'supplemental', 'template=internetcustom')
  return [pscustomobject]@{
    Global    = ConvertFrom-PcbNetshShow ([string]$g.Output)
    Supplemental = ConvertFrom-PcbNetshShow ([string]$s.Output)
  }
}

function Get-PcbNicList {
  if ($null -ne $script:PcbNicAdapters) { return @(& $script:PcbNicAdapters) }
  if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return @() }
  try {
    return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' })
  } catch { return @() }
}

function Get-PcbNicLabel($Adapter) {
  # A Korean adapter alias ('??') becomes '???' once Write-PcbLine folds non-ASCII to
  # '?', so a non-ASCII alias is replaced in the ROW LABEL by the driver description.
  # The adapter Name is still what every cmdlet call and state.json use.
  if ($null -eq $Adapter) { return '' }
  $nm = [string]$Adapter.Name
  if ($nm -match '[^\x20-\x7E]') {
    $desc = ''
    try { $desc = [string]$Adapter.InterfaceDescription } catch { $desc = '' }
    if (-not [string]::IsNullOrWhiteSpace($desc)) { return $desc }
  }
  return $nm
}

function Get-PcbNicProp($Name, [string]$Keyword) {
  if ($null -ne $script:PcbNicPropGet) { return (& $script:PcbNicPropGet $Name $Keyword) }
  try {
    return @(Get-NetAdapterAdvancedProperty -Name $Name -AllProperties -RegistryKeyword $Keyword -ErrorAction Stop)[0]
  } catch { return $null }
}

function Set-PcbNicProp($Name, [string]$Keyword, [string]$Value) {
  if ($null -ne $script:PcbNicPropSet) { & $script:PcbNicPropSet $Name $Keyword $Value; return }
  Set-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $Keyword -RegistryValue $Value -NoRestart -ErrorAction Stop | Out-Null
}

function Get-PcbNicBindings($Name) {
  if ($null -ne $script:PcbNicBindGet) { return @(& $script:PcbNicBindGet $Name) }
  try { return @(Get-NetAdapterBinding -Name $Name -AllBindings -ErrorAction Stop) } catch { return @() }
}

function Set-PcbNicBinding($Name, [string]$ComponentId, [bool]$Enabled) {
  if ($null -ne $script:PcbNicBindSet) { & $script:PcbNicBindSet $Name $ComponentId $Enabled; return }
  if ($Enabled) {
    Enable-NetAdapterBinding -Name $Name -ComponentID $ComponentId -ErrorAction Stop | Out-Null
  } else {
    Disable-NetAdapterBinding -Name $Name -ComponentID $ComponentId -ErrorAction Stop | Out-Null
  }
}

# A NIC write only takes effect on the next adapter restart, and the restart drops the
# link for a few seconds - which is exactly why a test must be able to replace it.
function Restart-PcbNic([string]$Name) {
  if ($null -ne $script:PcbNicRestart) { & $script:PcbNicRestart $Name; return }
  Restart-NetAdapter -Name $Name -ErrorAction Stop | Out-Null
}

function Invoke-PcbStepNic {
  param($Masks = $null)
  if ($NoNic) {
    Add-PcbRow 'c' 'nic' 'n/a' 'n/a' 'SKIP: -NoNic' | Out-Null
    return
  }
  if ($null -eq $script:PcbNicAdapters -and -not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'c' 'nic' 'n/a' 'n/a' 'SKIP: NetAdapter module not available' | Out-Null
    return
  }
  $recs = New-Object System.Collections.ArrayList
  foreach ($n in @(Get-PcbNicList)) {
    $any = $false
    $lbl = Get-PcbNicLabel $n
    foreach ($spec in $script:PcbNicKeywords) {
      $kv = $spec.Split('=')
      $kw = $kv[0]
      $want = $kv[1]
      $prop = Get-PcbNicProp $n.Name $kw
      if ($null -eq $prop) {
        Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) 'absent' 'absent' 'SKIP: keyword not supported' | Out-Null
        continue
      }
      # a keyword the driver exposes but does not let you pick this value
      $valid = $null
      if ($null -ne $prop.PSObject.Properties['ValidRegistryValues']) { $valid = @($prop.ValidRegistryValues) }
      if ($null -ne $valid -and @($valid).Count -gt 0) {
        $hit = $false
        foreach ($v in @($valid)) { if ([string]$v -eq $want) { $hit = $true; break } }
        if (-not $hit) {
          Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) ([string]$prop.RegistryValue) ([string]$prop.RegistryValue) 'SKIP: value not offered' | Out-Null
          continue
        }
      }
      $old = [string]$prop.RegistryValue
      if ($old -eq $want) {
        Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) $old $old 'SKIP: already set' | Out-Null
        continue
      }
      if ($script:PcbDryRun) {
        Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) $old $want 'DRYRUN' | Out-Null
        continue
      }
      try {
        Set-PcbNicProp $n.Name $kw $want
        $now = Get-PcbNicProp $n.Name $kw
        [void]$recs.Add(@{ Name = $n.Name; Keyword = $kw; Old = $old })
        $any = $true
        $nowV = $want
        if ($null -ne $now) { $nowV = [string]$now.RegistryValue }
        $st = 'OK'
        if ($nowV -ne $want) { $st = 'FAIL: read-back differs' }
        Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) $old $nowV $st | Out-Null
      } catch {
        Add-PcbRow 'c' ('nic/' + $lbl + '/' + $kw) $old $want ('FAIL: ' + $_.Exception.Message) | Out-Null
      }
    }
    $any = (Invoke-PcbNicBindings $n $lbl $recs) -or $any
    if ($any -and -not $script:PcbDryRun) {
      Write-PcbLine 'network drops ~5 s'
      try { Restart-PcbNic $n.Name } catch {
        Add-PcbRow 'c' ('nic/' + $lbl + '/restart') 'up' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
      }
    }
  }
  $script:PcbState['Nic'] = @($recs)
  Save-PcbState
  Invoke-PcbNicNetsh
  Invoke-PcbNicUdp
}

function Invoke-PcbNicBindings($Adapter, [string]$Label, $Recs) {
  $any = $false
  $bindings = @(Get-PcbNicBindings $Adapter.Name)
  foreach ($cid in $script:PcbNicBindings) {
    $item = 'nic/' + $Label + '/bind/' + $cid
    $b = $null
    foreach ($x in $bindings) { if ($null -ne $x -and [string]$x.ComponentID -eq $cid) { $b = $x; break } }
    if ($null -eq $b) {
      Add-PcbRow 'c' $item 'absent' 'absent' 'SKIP: binding not present' | Out-Null
      continue
    }
    if (-not [bool]$b.Enabled) {
      Add-PcbRow 'c' $item 'disabled' 'disabled' 'SKIP: already disabled' | Out-Null
      continue
    }
    if ($script:PcbDryRun) {
      Add-PcbRow 'c' $item 'enabled' 'disabled' 'DRYRUN' | Out-Null
      continue
    }
    try {
      Set-PcbNicBinding $Adapter.Name $cid $false
      $now = $null
      foreach ($x in @(Get-PcbNicBindings $Adapter.Name)) { if ($null -ne $x -and [string]$x.ComponentID -eq $cid) { $now = $x; break } }
      [void]$Recs.Add(@{ Name = $Adapter.Name; Binding = $cid })
      $any = $true
      $st = 'OK'
      if ($null -ne $now -and [bool]$now.Enabled) { $st = 'FAIL: still enabled' }
      Add-PcbRow 'c' $item 'enabled' 'disabled' $st | Out-Null
    } catch {
      Add-PcbRow 'c' $item 'enabled' 'disabled' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  return $any
}

# `netsh -c int tcp dump` prints the live configuration as one replayable
# "set global a=b c=d ..." line.  That line is what revert replays, so the restore does
# not have to guess a Windows default per knob and does not depend on localized labels.
function Get-PcbNetshTcpDumpLine {
  $r = Invoke-PcbNetsh @('-c', 'int', 'tcp', 'dump')
  foreach ($ln in ([string]$r.Output).Split("`n")) {
    $t = $ln.Trim()
    if ($t -match '^set\s+global\s+\S') { return $t }
  }
  return ''
}

# 'set global rss=enabled ... rsc=disabled ...' -> @{ rsc = 'disabled' }  (lowercase keys)
function ConvertFrom-PcbNetshSetLine([string]$Line) {
  $map = @{}
  $t = ([string]$Line).Trim()
  if ($t -notmatch '^set\s+global\s+') { return $map }
  foreach ($kv in ($t -replace '^set\s+global\s+', '').Split(' ')) {
    $i = $kv.IndexOf('=')
    if ($i -le 0) { continue }
    $map[$kv.Substring(0, $i).ToLower()] = $kv.Substring($i + 1)
  }
  return $map
}

function Invoke-PcbNicNetsh {
  $before = Get-PcbNetshSnapshot
  $beforeLine = ''
  try { $beforeLine = Get-PcbNetshTcpDumpLine } catch { $beforeLine = '' }
  $beforeMap = ConvertFrom-PcbNetshSetLine $beforeLine
  $applied = New-Object System.Collections.ArrayList
  foreach ($cmd in $script:PcbNetshCommands) {
    $item = 'netsh/' + $cmd
    if ($script:PcbDryRun) {
      Add-PcbRow 'c' $item '(current)' '(set)' 'DRYRUN' | Out-Null
      continue
    }
    $args2 = @($cmd.Split(' '))
    $r = Invoke-PcbNetsh $args2
    if ([int]$r.Code -ne 0) {
      $msg = 'netsh rc ' + $r.Code
      foreach ($ln in ([string]$r.Output).Split("`n")) { $t = $ln.Trim(); if ($t.Length -gt 0) { $msg = $t; break } }
      Add-PcbRow 'c' $item '(current)' '(unchanged)' ('SKIP: ' + $msg) | Out-Null
      continue
    }
    [void]$applied.Add($cmd)
  }
  if (-not $script:PcbDryRun -and $applied.Count -gt 0) {
    # live read-back: the knob named in the command is looked up in the dump line after
    # the write.  netsh prints 'Ok.' even when it ignores a value, so the read is the proof.
    $afterLine = ''
    try { $afterLine = Get-PcbNetshTcpDumpLine } catch { $afterLine = '' }
    $afterMap = ConvertFrom-PcbNetshSetLine $afterLine
    foreach ($cmd in @($applied)) {
      $item = 'netsh/' + $cmd
      $pair = @($cmd.Split(' ') | Where-Object { $_ -match '=' })
      $want = ''
      $got = ''
      if (@($pair).Count -gt 0) {
        $kv = ([string]$pair[0]).Split('=')
        $want = [string]$kv[1]
        if ($afterMap.ContainsKey($kv[0].ToLower())) { $got = [string]$afterMap[$kv[0].ToLower()] }
      }
      $bTxt = 'unread'
      if (@($pair).Count -gt 0) {
        $kv = ([string]$pair[0]).Split('=')
        if ($beforeMap.ContainsKey($kv[0].ToLower())) { $bTxt = [string]$beforeMap[$kv[0].ToLower()] }
      }
      if ($want.Length -gt 0 -and $got -eq $want) {
        Add-PcbRow 'c' $item $bTxt $got 'OK' | Out-Null
      } else {
        Add-PcbRow 'c' $item $bTxt $got 'OK (written)' | Out-Null
      }
    }
    $script:PcbState['Netsh'] = @{ Before = $before; Applied = @($applied); DumpLine = $beforeLine }
    Save-PcbState
  }
}

# ---------------------------------------------------------------------------
# step c - UDP: receive offload and the LoL DSCP mark (W-UDP1)
# ---------------------------------------------------------------------------
# URO: `netsh int udp set global uro=disabled` prints "Ok." whether or not anything
# changed, so the only proof is a read of "Receive Offload State" out of
# `netsh int udp show global`.  Read before, write, read after.
$script:PcbUroRead = $null           # scriptblock -> state string ('enabled'/'disabled'/'')

function Get-PcbUdpUroState {
  if ($null -ne $script:PcbUroRead) { return ([string](& $script:PcbUroRead)).Trim() }
  $r = Invoke-PcbNetsh @('int', 'udp', 'show', 'global')
  # The label is localized on a Korean Windows, so the state is taken by position:
  # the udp global block lists exactly two states and the first one is receive.
  $states = New-Object System.Collections.ArrayList
  foreach ($ln in ([string]$r.Output).Split("`n")) {
    $t = $ln.Trim()
    $i = $t.IndexOf(':')
    if ($i -le 0) { continue }
    $v = $t.Substring($i + 1).Trim()
    if ($v -eq 'disabled' -or $v -eq 'enabled') { [void]$states.Add($v) }
  }
  if ($states.Count -gt 0) { return [string]$states[0] }
  return ''
}

# DSCP 46 for LoL's UDP: an ActiveStore QoS policy marks the packets at once and is
# gone again at the next boot (opus-recompute-tos.txt: a/b carry 0xb8 with the policy
# up, c carries 0x0 once it is removed).  PersistentStore and the Tcpip\QoS key are
# never written.
$script:PcbQosPolicyName = 'pcbang-lol-udp'
$script:PcbQosAppName = 'League of Legends.exe'

function Get-PcbQosPolicy([string]$Name) {
  if ($null -ne $script:PcbQosGet) { return (& $script:PcbQosGet $Name) }
  try { return (Get-NetQosPolicy -PolicyStore ActiveStore -Name $Name -ErrorAction Stop) } catch { return $null }
}

function Add-PcbQosPolicy([string]$Name) {
  if ($null -ne $script:PcbQosAdd) { & $script:PcbQosAdd $Name; return }
  New-NetQosPolicy -Name $Name -PolicyStore ActiveStore -AppPathNameMatchCondition $script:PcbQosAppName -IPProtocolMatchCondition UDP -DSCPAction 46 -ErrorAction Stop | Out-Null
}

function Remove-PcbQosPolicy([string]$Name) {
  if ($null -ne $script:PcbQosRemove) { & $script:PcbQosRemove $Name; return }
  Remove-NetQosPolicy -Name $Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop | Out-Null
}

function Invoke-PcbNicUdp {
  # $script:PcbState['Udp'] is written by the caller so a -DryRun leaves no trace.
  $uroBefore = ''
  try { $uroBefore = Get-PcbUdpUroState } catch { $uroBefore = '' }
  $item = 'udp/uro'
  if ($script:PcbDryRun) {
    $b = 'unknown'
    if ($uroBefore) { $b = $uroBefore }
    Add-PcbRow 'c' $item $b 'disabled' 'DRYRUN' | Out-Null
  } elseif ($uroBefore -eq 'disabled') {
    Add-PcbRow 'c' $item 'disabled' 'disabled' 'SKIP: already disabled' | Out-Null
  } elseif (-not $uroBefore) {
    Add-PcbRow 'c' $item 'unknown' 'unknown' 'SKIP: state unreadable' | Out-Null
  } else {
    $r = Invoke-PcbNetsh @('int', 'udp', 'set', 'global', 'uro=disabled')
    $now = ''
    try { $now = Get-PcbUdpUroState } catch { $now = '' }
    if ([int]$r.Code -eq 0 -and $now -eq 'disabled') {
      $script:PcbState['Udp'] = @{ UroBefore = $uroBefore; UroWritten = $true }
      Save-PcbState
      Add-PcbRow 'c' $item $uroBefore $now 'OK' | Out-Null
    } else {
      $why = 'read-back ' + $now
      if ([int]$r.Code -ne 0) { $why = 'rc ' + $r.Code + ' / ' + (Get-PcbNetshFirstLine $r.Output) }
      Add-PcbRow 'c' $item $uroBefore $now ('SKIP: ' + $why) | Out-Null
    }
  }

  $item = 'udp/dscp-lol'
  $existing = $null
  try { $existing = Get-PcbQosPolicy $script:PcbQosPolicyName } catch { $existing = $null }
  if ($null -ne $existing) {
    Add-PcbRow 'c' $item 'present' 'present' 'SKIP: policy already in ActiveStore' | Out-Null
    return
  }
  if ($script:PcbDryRun) {
    Add-PcbRow 'c' $item 'absent' 'DSCP 46 UDP' 'DRYRUN' | Out-Null
    return
  }
  try {
    Add-PcbQosPolicy $script:PcbQosPolicyName
    $now = $null
    try { $now = Get-PcbQosPolicy $script:PcbQosPolicyName } catch { $now = $null }
    if ($null -ne $now) {
      $txt = 'DSCP 46 UDP'
      if ($null -ne $now.PSObject.Properties['DSCPAction']) { $txt = 'DSCP ' + [string]$now.DSCPAction + ' UDP' }
      $u = $script:PcbState['Udp']
      if ($null -eq $u) { $u = @{} }
      $u['QosName'] = $script:PcbQosPolicyName
      $script:PcbState['Udp'] = $u
      Save-PcbState
      Add-PcbRow 'c' $item 'absent' $txt 'OK' | Out-Null
    } else {
      Add-PcbRow 'c' $item 'absent' 'DSCP 46 UDP' 'SKIP: policy not visible after add' | Out-Null
    }
  } catch {
    Add-PcbRow 'c' $item 'absent' 'DSCP 46 UDP' ('SKIP: ' + $_.Exception.Message) | Out-Null
  }
}

# Reverse order: the QoS policy first (it needs the driver path), then URO.
function Restore-PcbNicUdp {
  if ($script:PcbDryRun) { return }
  $u = $script:PcbState['Udp']
  if ($null -eq $u) { return }
  $qosName = [string](Get-PcbStateField $u 'QosName')
  if ($qosName) {
    try {
      Remove-PcbQosPolicy $qosName
      $now = Get-PcbQosPolicy $qosName
      $st = 'OK'
      if ($null -ne $now) { $st = 'FAIL: policy still present' }
      Add-PcbRow 'r' 'udp/dscp-lol' '(present)' 'absent' $st | Out-Null
    } catch {
      Add-PcbRow 'r' 'udp/dscp-lol' '(present)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  if ([bool](Get-PcbStateField $u 'UroWritten')) {
    $want = [string](Get-PcbStateField $u 'UroBefore')
    $r = Invoke-PcbNetsh @('int', 'udp', 'set', 'global', ('uro=' + $want))
    $now = ''
    try { $now = Get-PcbUdpUroState } catch { $now = '' }
    $st = 'OK'
    if ($now -ne $want) { $st = 'FAIL: read-back ' + $now }
    if ([int]$r.Code -ne 0) { $st = 'FAIL: rc ' + $r.Code }
    Add-PcbRow 'r' 'udp/uro' '(tuned)' $now $st | Out-Null
  }
}

function Restore-PcbNic {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['Nic']
  if ($null -eq $recs) { $recs = @() }
  $touched = @{}
  foreach ($r in @($recs)) {
    if ($null -eq $r) { continue }
    try {
      if ($null -ne (Get-PcbStateField $r 'Binding')) {
        Set-PcbNicBinding ([string]$r.Name) ([string]$r.Binding) $true
        $touched[[string]$r.Name] = 1
        Add-PcbRow 'r' ('nic/' + $r.Name + '/bind/' + [string]$r.Binding) 'disabled' 'enabled' 'OK' | Out-Null
        continue
      }
      if ($null -ne (Get-PcbStateField $r 'Rss')) { continue }
      Set-PcbNicProp ([string]$r.Name) ([string]$r.Keyword) ([string]$r.Old)
      $touched[[string]$r.Name] = 1
      Add-PcbRow 'r' ('nic/' + $r.Name + '/' + $r.Keyword) '(tuned)' $r.Old 'OK' | Out-Null
    } catch {
      Add-PcbRow 'r' ('nic/' + [string]$r.Name) '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  $ns = $script:PcbState['Netsh']
  foreach ($cmd in @($script:PcbNetshCommands)) {
    $item = 'netsh/' + $cmd
    if ($null -eq $ns) {
      Add-PcbRow 'r' $item '(tuned)' '(unchanged)' 'SKIP: kit did not write it' | Out-Null
      continue
    }
    $did = $false
    foreach ($a in @($ns.Applied)) { if ([string]$a -eq $cmd) { $did = $true; break } }
    if (-not $did) {
      Add-PcbRow 'r' $item '(tuned)' '(unchanged)' 'SKIP: kit did not write it' | Out-Null
      continue
    }
    # the knobs this command wrote are looked up in the dump taken BEFORE the write and
    # only those are put back; everything else netsh touched stays as it is now.
    $inv = $null
    $kvWant = @($cmd.Split(' ') | Where-Object { $_ -match '=' })
    $savedLine = ''
    $savedLine = [string](Get-PcbStateField $ns 'DumpLine')
    $savedMap = ConvertFrom-PcbNetshSetLine $savedLine
    $invParts = New-Object System.Collections.ArrayList
    foreach ($p in @($kvWant)) {
      $kv = ([string]$p).Split('=')
      $key = $kv[0].ToLower()
      if (-not $savedMap.ContainsKey($key)) { continue }
      [void]$invParts.Add($kv[0] + '=' + [string]$savedMap[$key])
    }
    $good = ($invParts.Count -gt 0)
    if ($good) {
      $inv = @('int', 'tcp', 'set', 'global') + @($invParts.ToArray())
    } else {
      # no saved line (state written by an older kit): fall back to the Windows default
      $inv = @($cmd.Split(' '))
      if ($cmd -like '*rsc=disabled*') { $inv = @('int', 'tcp', 'set', 'global', 'rsc=enabled') }
      if ($cmd -like '*initialRto=300*') { $inv = @('int', 'tcp', 'set', 'global', 'initialRto=1000') }
    }
    $r = Invoke-PcbNetsh $inv
    if ([int]$r.Code -eq 0) {
      $afterLine = ''
      try { $afterLine = Get-PcbNetshTcpDumpLine } catch { $afterLine = '' }
      $afterMap = ConvertFrom-PcbNetshSetLine $afterLine
      $done = New-Object System.Collections.ArrayList
      foreach ($p in @($invParts.ToArray())) {
        $kv = ([string]$p).Split('=')
        $got = '?'
        if ($afterMap.ContainsKey($kv[0].ToLower())) { $got = [string]$afterMap[$kv[0].ToLower()] }
        [void]$done.Add($kv[0] + '=' + $got)
      }
      $txt = 'restored ' + (@($done.ToArray()) -join ' ')
      $st = 'OK'
      if (@($done.ToArray()).Count -eq 0) { $txt = 'restored ' + ($inv -join ' ') }
      Add-PcbRow 'r' $item '(tuned)' $txt $st | Out-Null
    } else {
      Add-PcbRow 'r' $item '(tuned)' 'unknown' ('FAIL: ' + (Get-PcbNetshFirstLine $r.Output)) | Out-Null
    }
  }
  foreach ($k in @($touched.Keys)) {
    Write-PcbLine 'network drops ~5 s'
    try { Restart-PcbNic $k } catch { }
  }
}

function Get-PcbNetshFirstLine([string]$Text) {
  foreach ($ln in ([string]$Text).Split("`n")) { $t = $ln.Trim(); if ($t.Length -gt 0) { return $t } }
  return 'no output'
}

# ===========================================================================
# step c2 - IRQ pins (module from W-PCB3, optional)
# ===========================================================================

function Invoke-PcbStepIrq {
  param($Masks)
  if ($NoIrq) {
    Add-PcbRow 'c2' 'irq' 'n/a' 'n/a' 'SKIP: -NoIrq' | Out-Null
    return
  }
  if (-not (Get-Command Set-PcbIrqPins -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'c2' 'irq' 'n/a' 'n/a' 'SKIP: irq module absent' | Out-Null
    return
  }
  # The GPU pin needs a restart of the display adapter before it takes effect.  That
  # restart was measured on this PC (dxgkrnl ISR moved to CPU15 after pin 0x8000, GPU
  # came back OK), so the gpu target is part of the default list.  -NoGpuIrq drops it
  # and records a row saying so.  Only Role 'gpu' is dropped - the input controllers
  # ('mouse-xhci', 'kbd-xhci') stay in the list.
  $targets = $null
  $gpuDropped = $null
  if ($NoGpuIrq -and (Get-Command Get-PcbIrqTargets -ErrorAction SilentlyContinue)) {
    try {
      $all = @(Get-PcbIrqTargets)
      $keep = New-Object System.Collections.ArrayList
      foreach ($t in $all) {
        if ($null -eq $t) { continue }
        if ([string]$t.Role -eq 'gpu') { $gpuDropped = $t; continue }
        [void]$keep.Add($t)
      }
      $targets = @($keep)
    } catch {
      $targets = $null
      $gpuDropped = $null
    }
  }
  try {
    $sp = @{ IrqMask = $Masks.IrqMask; DryRun = [bool]$DryRun }
    if ($null -ne $targets) { $sp['Targets'] = $targets }
    $r = Set-PcbIrqPins @sp
    if ($r) { $script:PcbState['Irq'] = $r.Before }
    Save-PcbState
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      $st = [string]$row.Status
      # dry-run rows from the irq module read 'OK (dry-run) cpu N'; the kit's row
      # contract is DRYRUN for anything that would have changed, so normalise here and
      # keep the chosen cpu visible in the Status column.
      if ($script:PcbDryRun -and -not ($st -like 'SKIP*') -and -not ($st -like 'FAIL*')) {
        $cpuTag = [regex]::Match($st, '(?i)\bcpu\s*([0-9]+)')
        if ($cpuTag.Success) { $st = 'DRYRUN cpu ' + $cpuTag.Groups[1].Value } else { $st = 'DRYRUN' }
      }
      # W-PCB7B rows carry a Kind ('irq' | 'value' | 'restart') and a Detail column
      # ('OK <value name>', 'msi=yes|no').  The kit's row shape has neither, so both go
      # after the verdict: the kind in brackets (a value row would otherwise be
      # indistinguishable from the pin row above it) and then the detail, so the msi
      # verdict is not lost.  The verdict stays first because every row contract in this
      # kit is read from the start of Status ('DRYRUN', 'SKIP: ...', 'FAIL: ...').
      # Item/Before/After keep their columns - prefixing Item would truncate the id.
      $kind = ''
      if ($null -ne $row.PSObject.Properties['Step']) { $kind = [string]$row.Step }
      $detail = ''
      if ($null -ne $row.PSObject.Properties['Detail']) { $detail = ([string]$row.Detail).Trim() }
      if ($kind) { $st = $st + ' [' + $kind + ']' }
      if ($detail) { $st = $st + ' | ' + $detail }
      Add-PcbRow 'c2' ([string]$row.Item) $row.Before $row.After $st | Out-Null
    }
    if (@($r.Rows).Count -eq 0) {
      Add-PcbRow 'c2' 'irq' 'n/a' 'n/a' 'SKIP: module returned no targets' | Out-Null
    }
  } catch {
    Add-PcbRow 'c2' 'irq' 'n/a' 'n/a' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
  if ($null -ne $gpuDropped) {
    $gid = [string]$gpuDropped.InstanceId
    Add-PcbRow 'c2' ('gpu ' + $gid) 'unchanged' 'unchanged' 'SKIP: -NoGpuIrq' | Out-Null
  }
}

function Restore-PcbIrq {
  if ($script:PcbDryRun) { return }
  $rec = $script:PcbState['Irq']
  if ($null -eq $rec) { return }
  if (-not (Get-Command Restore-PcbIrqPins -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'r' 'irq' 'n/a' 'n/a' 'SKIP: irq module absent' | Out-Null
    return
  }
  try {
    $r = Restore-PcbIrqPins -Before $rec
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      Add-PcbRow 'r' ([string]$row.Item) $row.Before $row.After ([string]$row.Status) | Out-Null
    }
  } catch {
    Add-PcbRow 'r' 'irq' 'n/a' 'n/a' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

# ===========================================================================
# step d - registry
# ===========================================================================

function Get-PcbRegValue([string]$Path, [string]$Name) {
  $rec = @{ Existed = $false; Value = $null; Kind = 'DWord' }
  if (-not (Test-Path -LiteralPath $Path)) { return $rec }
  $item = $null
  try { $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop } catch { return $rec }
  if ($null -eq $item) { return $rec }
  $val = $null
  try { $val = $item.$Name } catch { return $rec }
  if ($null -eq $val) { return $rec }
  $rec.Existed = $true
  $rec.Value = $val
  try { $rec.Kind = (Get-Item -LiteralPath $Path).GetValueKind($Name).ToString() } catch { }
  return $rec
}

function Set-PcbRegValue([string]$Path, [string]$Name, [string]$Kind, $Value) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
  if ($Kind -eq 'DWord') {
    New-ItemProperty -LiteralPath $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force | Out-Null
  } elseif ($Kind -eq 'String') {
    New-ItemProperty -LiteralPath $Path -Name $Name -Value ([string]$Value) -PropertyType String -Force | Out-Null
  } else {
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Force | Out-Null
  }
}

function Get-PcbLolExe {
  $yaml = 'C:\ProgramData\Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml'
  $roots = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath $yaml) {
    $txt = ''
    try { $txt = Get-Content -LiteralPath $yaml -Raw -ErrorAction Stop } catch { $txt = '' }
    $m = [regex]::Match($txt, 'product_install_full_path:\s*"?([^"\r\n]+)"?')
    if ($m.Success) { [void]$roots.Add(($m.Groups[1].Value.Trim() -replace '/', '\')) }
  }
  [void]$roots.Add('C:\Riot Games\League of Legends')
  [void]$roots.Add('D:\Riot Games\League of Legends')
  foreach ($r in $roots) {
    $exe = Join-Path $r 'Game\League of Legends.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
  }
  return $null
}

function Get-PcbDxPrefsTarget {
  # DirectXUserGlobalSettings is a REG_SZ of 'Key=Value;' pairs under UserGpuPreferences.
  # Path/name are overridable so a test can drive a throw-away key.
  $path = $script:PcbDxPath
  if ([string]::IsNullOrWhiteSpace($path)) { $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' }
  $name = $script:PcbDxName
  if ([string]::IsNullOrWhiteSpace($name)) { $name = 'DirectXUserGlobalSettings' }
  return [pscustomobject]@{ Path = $path; Name = $name }
}

# Splits 'A=1;B=2;' into ordered pairs and a flag for a trailing semicolon.
function ConvertFrom-PcbPairString([string]$text) {
  $pairs = New-Object System.Collections.ArrayList
  if ($null -eq $text) { return [pscustomobject]@{ Pairs = @(); Trailing = $false } }
  $t = [string]$text
  $trailing = $false
  if ($t.Length -gt 0 -and $t.EndsWith(';')) { $trailing = $true }
  foreach ($seg in $t.Split(';')) {
    if ([string]::IsNullOrEmpty($seg)) { continue }
    $eq = $seg.IndexOf('=')
    if ($eq -lt 0) {
      [void]$pairs.Add([pscustomobject]@{ Key = $seg; Value = $null })
    } else {
      [void]$pairs.Add([pscustomobject]@{ Key = $seg.Substring(0, $eq); Value = $seg.Substring($eq + 1) })
    }
  }
  return [pscustomobject]@{ Pairs = @($pairs); Trailing = $trailing }
}

function Set-PcbPairValue([string]$text, [string]$key, [string]$value) {
  # keeps every other pair and its order; an existing key is replaced in place.
  $parsed = ConvertFrom-PcbPairString $text
  $out = New-Object System.Collections.ArrayList
  $done = $false
  foreach ($p in @($parsed.Pairs)) {
    if ([string]$p.Key -eq $key) {
      if ($done) { continue }
      [void]$out.Add($key + '=' + $value)
      $done = $true
      continue
    }
    if ($null -eq $p.Value) { [void]$out.Add([string]$p.Key) } else { [void]$out.Add([string]$p.Key + '=' + [string]$p.Value) }
  }
  if (-not $done) { [void]$out.Add($key + '=' + $value) }
  if ($out.Count -eq 0) { return '' }
  return (($out -join ';') + ';')
}

function Invoke-PcbStepDxPrefs {
  $tgt = Get-PcbDxPrefsTarget
  $item = 'dx/SwapEffectUpgradeEnable'
  try {
    $pre = Get-PcbRegValue $tgt.Path $tgt.Name
    $before = 'absent'
    if ($pre.Existed) { $before = [string]$pre.Value }
    $old = $null
    if ($pre.Existed) { $old = [string]$pre.Value }
    $want = Set-PcbPairValue $old 'SwapEffectUpgradeEnable' '1'
    if ($script:PcbDryRun) {
      Add-PcbRow 'd' $item $before $want 'DRYRUN' | Out-Null
      return
    }
    Set-PcbRegValue $tgt.Path $tgt.Name 'String' $want
    $post = Get-PcbRegValue $tgt.Path $tgt.Name
    $after = 'absent'
    if ($post.Existed) { $after = [string]$post.Value }
    $script:PcbState['DxPrefs'] = @(@{ Path = $tgt.Path; Name = $tgt.Name; Existed = [bool]$pre.Existed; Value = $pre.Value })
    Save-PcbState
    if ($post.Existed -and [string]$post.Value -eq $want) {
      Add-PcbRow 'd' $item $before $after 'OK' | Out-Null
    } else {
      Add-PcbRow 'd' $item $before $after 'FAIL: write did not take' | Out-Null
    }
  } catch {
    Add-PcbRow 'd' $item 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbDxPrefs {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['DxPrefs']
  if ($null -eq $recs) { return }
  foreach ($r in @($recs)) {
    $item = 'dx/SwapEffectUpgradeEnable'
    try {
      if ($r.Existed) {
        Set-PcbRegValue ([string]$r.Path) ([string]$r.Name) 'String' ([string]$r.Value)
        Add-PcbRow 'r' $item '(tuned)' ([string]$r.Value) 'OK' | Out-Null
      } else {
        if (Test-Path -LiteralPath ([string]$r.Path)) {
          Remove-ItemProperty -LiteralPath ([string]$r.Path) -Name ([string]$r.Name) -ErrorAction SilentlyContinue
        }
        Add-PcbRow 'r' $item '(tuned)' 'absent' 'OK' | Out-Null
      }
    } catch {
      Add-PcbRow 'r' $item '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
}

function Invoke-PcbStepRegistry {
  $rows = New-Object System.Collections.ArrayList
  $targets = @(
    @{ Item = 'PriorityControl/Win32PrioritySeparation'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Kind = 'DWord'; Want = 0x26 },
    @{ Item = 'GameConfigStore/GameDVR_Enabled';            Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Kind = 'DWord'; Want = 0 },
    @{ Item = 'GameDVR/AppCaptureEnabled';                  Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Kind = 'DWord'; Want = 0 },
    @{ Item = 'GameBar/AutoGameModeEnabled';                Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Kind = 'DWord'; Want = 1 },
    @{ Item = 'GameBar/AllowAutoGameMode';                  Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Kind = 'DWord'; Want = 1 }
  )
  # MMCSS (SystemProfile / Tasks\Games) is deliberately not here: mmcss.sys is a boot
  # device driver, so its values are read once at boot and a write does nothing until the
  # next restart.  Amendment 1 of W-PCB7A drops those rows.
  $exe = Get-PcbLolExe
  if ($exe) {
    $targets += @{ Item = 'FSO/LoL'; Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'; Name = $exe; Kind = 'String'; Want = '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' }
  } else {
    Add-PcbRow 'd' 'FSO/LoL' 'n/a' 'n/a' 'SKIP: League of Legends.exe not found' | Out-Null
  }
  foreach ($t in $targets) {
    try {
      $pre = Get-PcbRegValue $t.Path $t.Name
      $bs = 'absent'
      if ($pre.Existed) { $bs = [string]$pre.Value }
      if ($script:PcbDryRun) {
        Add-PcbRow 'd' $t.Item $bs ([string]$t.Want) 'DRYRUN' | Out-Null
        continue
      }
      Set-PcbRegValue $t.Path $t.Name $t.Kind $t.Want
      $post = Get-PcbRegValue $t.Path $t.Name
      $as = 'absent'
      if ($post.Existed) { $as = [string]$post.Value }
      [void]$rows.Add(@{ Path = $t.Path; Name = $t.Name; Kind = $t.Kind; Existed = $pre.Existed; Value = $pre.Value })
      if ([string]$post.Value -eq [string]$t.Want) {
        Add-PcbRow 'd' $t.Item $bs $as 'OK' | Out-Null
      } else {
        Add-PcbRow 'd' $t.Item $bs $as 'FAIL: write did not take' | Out-Null
      }
    } catch {
      Add-PcbRow 'd' $t.Item 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  $script:PcbState['Registry'] = @($rows)
  Save-PcbState
  Invoke-PcbStepDxPrefs
  Invoke-PcbStepLolGpuPref
}

# The home state sets GpuPreference=2 (high performance) for the game exe.  The value is
# one 'Key=Value;' pair inside a REG_SZ named after the exe's full path, so it is merged
# like DirectXUserGlobalSettings: every other pair and the old string are preserved.
$script:PcbGpuPrefPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

function Invoke-PcbStepLolGpuPref {
  $item = 'dx/LoL-GpuPreference'
  $exe = Get-PcbLolExe
  if (-not $exe) {
    Add-PcbRow 'd' $item 'n/a' 'n/a' 'SKIP: League of Legends.exe not found' | Out-Null
    return
  }
  try {
    $pre = Get-PcbRegValue $script:PcbGpuPrefPath $exe
    $before = 'absent'
    if ($pre.Existed) { $before = [string]$pre.Value }
    $old = $null
    if ($pre.Existed) { $old = [string]$pre.Value }
    $want = Set-PcbPairValue $old 'GpuPreference' '2'
    if ($script:PcbDryRun) {
      Add-PcbRow 'd' $item $before $want 'DRYRUN' | Out-Null
      return
    }
    Set-PcbRegValue $script:PcbGpuPrefPath $exe 'String' $want
    $post = Get-PcbRegValue $script:PcbGpuPrefPath $exe
    $after = 'absent'
    if ($post.Existed) { $after = [string]$post.Value }
    $recs = @($script:PcbState['GpuPref'])
    $recs += @{ Path = $script:PcbGpuPrefPath; Name = $exe; Existed = [bool]$pre.Existed; Value = $pre.Value }
    $script:PcbState['GpuPref'] = @($recs)
    Save-PcbState
    if ($post.Existed -and [string]$post.Value -eq $want) {
      Add-PcbRow 'd' $item $before $after 'OK' | Out-Null
    } else {
      Add-PcbRow 'd' $item $before $after 'FAIL: write did not take' | Out-Null
    }
  } catch {
    Add-PcbRow 'd' $item 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbGpuPref {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['GpuPref']
  if ($null -eq $recs) { return }
  foreach ($r in @($recs)) {
    $item = 'dx/LoL-GpuPreference'
    try {
      if ([bool]$r.Existed) {
        Set-PcbRegValue ([string]$r.Path) ([string]$r.Name) 'String' ([string]$r.Value)
        Add-PcbRow 'r' $item '(tuned)' ([string]$r.Value) 'OK' | Out-Null
      } else {
        if (Test-Path -LiteralPath ([string]$r.Path)) {
          Remove-ItemProperty -LiteralPath ([string]$r.Path) -Name ([string]$r.Name) -ErrorAction SilentlyContinue
        }
        Add-PcbRow 'r' $item '(tuned)' 'absent' 'OK' | Out-Null
      }
    } catch {
      Add-PcbRow 'r' $item '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
}

function Restore-PcbRegistry {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['Registry']
  if ($null -eq $recs) { return }
  foreach ($r in @($recs)) {
    try {
      if ($r.Existed) {
        Set-PcbRegValue $r.Path $r.Name $r.Kind $r.Value
        Add-PcbRow 'r' ('reg/' + $r.Name) '(tuned)' ([string]$r.Value) 'OK' | Out-Null
      } else {
        if (Test-Path -LiteralPath $r.Path) {
          Remove-ItemProperty -LiteralPath $r.Path -Name $r.Name -ErrorAction SilentlyContinue
        }
        Add-PcbRow 'r' ('reg/' + $r.Name) '(tuned)' 'absent' 'OK' | Out-Null
      }
    } catch {
      Add-PcbRow 'r' ('reg/' + $r.Name) '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
}

# ===========================================================================
# step e - mouse
# ===========================================================================

function Invoke-PcbStepMouse {
  Initialize-PcbNative
  $accel = $null
  try { $accel = [PcbNative]::GetMouseAccel() } catch { $accel = $null }
  $speed = -1
  try { $speed = [PcbNative]::GetMouseSpeed() } catch { $speed = -1 }
  if ($null -eq $accel -or $speed -lt 0) {
    Add-PcbRow 'e' 'mouse' 'unknown' 'unknown' 'SKIP: SPI read failed' | Out-Null
    return
  }
  $script:PcbState['Mouse'] = @{ Accel = @($accel); Speed = $speed }
  Save-PcbState
  $before = ('accel=' + ($accel -join ',') + ' speed=' + $speed)
  if ($script:PcbDryRun) {
    Add-PcbRow 'e' 'mouse' $before 'accel=0,0,0 speed=10' 'DRYRUN' | Out-Null
    return
  }
  $ok1 = $false
  $ok2 = $false
  try { $ok1 = [PcbNative]::SetMouseAccel(0, 0, 0) } catch { $ok1 = $false }
  try { $ok2 = [PcbNative]::SetMouseSpeed(10) } catch { $ok2 = $false }
  $a2 = [PcbNative]::GetMouseAccel()
  $s2 = [PcbNative]::GetMouseSpeed()
  $after = ('accel=' + ($a2 -join ',') + ' speed=' + $s2)
  # The read-back is the proof: a setter can return FALSE when the value is already in
  # place (SPI_SETMOUSESPEED refuses a no-op from a non-interactive context), so the row
  # is only a FAIL when the read-back is still off the target.
  $atTarget = ((($a2 -join ',') -eq '0,0,0') -and ([int]$s2 -eq 10))
  if ($atTarget) {
    Add-PcbRow 'e' 'mouse' $before $after 'OK' | Out-Null
  } elseif ($ok1 -and $ok2) {
    Add-PcbRow 'e' 'mouse' $before $after 'OK (written)' | Out-Null
  } else {
    Add-PcbRow 'e' 'mouse' $before $after ('FAIL: set ret ' + $ok1 + '/' + $ok2) | Out-Null
  }
}

function Restore-PcbMouse {
  if ($script:PcbDryRun) { return }
  $m = $script:PcbState['Mouse']
  if ($null -eq $m) { return }
  try {
    $a = @($m.Accel)
    [void][PcbNative]::SetMouseAccel([int]$a[0], [int]$a[1], [int]$a[2])
    if ([int]$m.Speed -gt 0) { [void][PcbNative]::SetMouseSpeed([int]$m.Speed) }
    $a2 = [PcbNative]::GetMouseAccel()
    $s2 = [PcbNative]::GetMouseSpeed()
    Add-PcbRow 'r' 'mouse' '(tuned)' ('accel=' + ($a2 -join ',') + ' speed=' + $s2) 'OK' | Out-Null
  } catch {
    Add-PcbRow 'r' 'mouse' '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

# ===========================================================================
# step f - services
# ===========================================================================

# The full home stop-only list (gaming-mode-apply.ps1:30-34) plus the NVIDIA container
# service nv-final.ps1 stops.  Behaviour is unchanged from earlier kits: stop only, never
# change StartType, and revert starts exactly the ones this run stopped.
$script:PcbServiceNames = @(
  'SysMain', 'WSearch', 'wuauserv', 'DoSvc', 'DiagTrack', 'dmwappushservice',
  'WpnService', 'CDPSvc', 'MapsBroker', 'RetailDemo', 'WalletService',
  'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
  'Fax', 'RemoteRegistry', 'WMPNetworkSvc', 'stisvc', 'WerSvc',
  'NvContainerLocalSystem'
)

function Invoke-PcbStepServices {
  $stopped = New-Object System.Collections.ArrayList
  foreach ($n in $script:PcbServiceNames) {
    $svc = $null
    try { $svc = Get-Service -Name $n -ErrorAction Stop } catch { $svc = $null }
    if ($null -eq $svc) {
      Add-PcbRow 'f' ('service/' + $n) 'absent' 'absent' 'SKIP: service not present' | Out-Null
      continue
    }
    if ($svc.Status -ne 'Running') {
      Add-PcbRow 'f' ('service/' + $n) ([string]$svc.Status) ([string]$svc.Status) ('SKIP: not running (StartType ' + $svc.StartType + ')') | Out-Null
      continue
    }
    if ($script:PcbDryRun) {
      Add-PcbRow 'f' ('service/' + $n) 'Running' 'Stopped' 'DRYRUN' | Out-Null
      continue
    }
    try {
      Stop-Service -Name $n -Force -ErrorAction Stop
      Start-Sleep -Milliseconds 300
      $now = Get-Service -Name $n
      [void]$stopped.Add($n)
      Add-PcbRow 'f' ('service/' + $n) 'Running' ([string]$now.Status) 'OK' | Out-Null
    } catch {
      Add-PcbRow 'f' ('service/' + $n) 'Running' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  $script:PcbState['Services'] = @($stopped)
  Save-PcbState
}

function Restore-PcbServices {
  if ($script:PcbDryRun) { return }
  $names = $script:PcbState['Services']
  if ($null -eq $names) { return }
  foreach ($n in @($names)) {
    try {
      Start-Service -Name $n -ErrorAction Stop
      Add-PcbRow 'r' ('service/' + $n) 'Stopped' ([string](Get-Service -Name $n).Status) 'OK' | Out-Null
    } catch {
      Add-PcbRow 'r' ('service/' + $n) 'Stopped' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
}

# ===========================================================================
# step f2 - scheduled tasks (maintenance + NVIDIA updater)
# ===========================================================================
#
# gaming-mode-apply.ps1:50-58 disables nine maintenance tasks in the home Gaming boot and
# nv-final.ps1:44-50 disables every Nv* task.  Both are handled the same way: disable the
# ones that are present AND enabled, record TaskPath+TaskName, and on revert enable only
# those.  Nothing here re-enables a task that was already disabled before the kit ran.

$script:PcbTaskPaths = @(
  '\Microsoft\Windows\Defrag\ScheduledDefrag',
  '\Microsoft\Windows\DiskFootprint\Diagnostics',
  '\Microsoft\Windows\DiskFootprint\StorageSense',
  '\Microsoft\Windows\Maintenance\WinSAT',
  '\Microsoft\Windows\Application Experience\StartupAppTask',
  '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
  '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
  '\Microsoft\Windows\Feedback\Siuf\DmClient',
  '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
)

function Invoke-PcbStepTasks {
  $recs = New-Object System.Collections.ArrayList
  if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'f2' 'task' 'n/a' 'n/a' 'SKIP: ScheduledTasks module not available' | Out-Null
    return
  }
  $list = New-Object System.Collections.ArrayList
  foreach ($p in $script:PcbTaskPaths) {
    $tp = Split-Path -Parent $p
    $tn = Split-Path -Leaf $p
    if ([string]::IsNullOrEmpty($tp)) { $tp = '\' }
    [void]$list.Add([pscustomobject]@{ Path = $tp; Name = $tn })
  }
  try {
    foreach ($t in @(Get-ScheduledTask -TaskName 'Nv*' -ErrorAction SilentlyContinue)) {
      if ($null -eq $t) { continue }
      [void]$list.Add([pscustomobject]@{ Path = [string]$t.TaskPath; Name = [string]$t.TaskName })
    }
  } catch { }
  foreach ($t in $list) {
    $item = 'task/' + $t.Name
    $tk = $null
    try { $tk = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop } catch { $tk = $null }
    if ($null -eq $tk) {
      Add-PcbRow 'f2' $item 'absent' 'absent' 'SKIP: task not present' | Out-Null
      continue
    }
    if ([string]$tk.State -eq 'Disabled') {
      Add-PcbRow 'f2' $item 'Disabled' 'Disabled' 'SKIP: already disabled' | Out-Null
      continue
    }
    if ($script:PcbDryRun) {
      Add-PcbRow 'f2' $item ([string]$tk.State) 'Disabled' 'DRYRUN' | Out-Null
      continue
    }
    try {
      Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
      $now = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop
      [void]$recs.Add(@{ Path = [string]$t.Path; Name = [string]$t.Name })
      if ([string]$now.State -eq 'Disabled') {
        Add-PcbRow 'f2' $item ([string]$tk.State) 'Disabled' 'OK' | Out-Null
      } else {
        Add-PcbRow 'f2' $item ([string]$tk.State) ([string]$now.State) 'FAIL: still enabled' | Out-Null
      }
    } catch {
      Add-PcbRow 'f2' $item ([string]$tk.State) 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  $script:PcbState['Tasks'] = @($recs)
  Save-PcbState
}

function Restore-PcbTasks {
  if ($script:PcbDryRun) { return }
  $recs = $script:PcbState['Tasks']
  if ($null -eq $recs) { return }
  foreach ($r in @($recs)) {
    $item = 'task/' + [string]$r.Name
    try {
      Enable-ScheduledTask -TaskPath ([string]$r.Path) -TaskName ([string]$r.Name) -ErrorAction Stop | Out-Null
      $now = Get-ScheduledTask -TaskPath ([string]$r.Path) -TaskName ([string]$r.Name) -ErrorAction Stop
      Add-PcbRow 'r' $item 'Disabled' ([string]$now.State) 'OK' | Out-Null
    } catch {
      Add-PcbRow 'r' $item 'Disabled' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
}

# ===========================================================================
# step g - NVIDIA (module from W-PCB2, optional)
# ===========================================================================

function Invoke-PcbStepNvidia {
  if (-not (Get-Command Set-PcbNvLol -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'g' 'nvidia' 'n/a' 'n/a' 'SKIP: nvidia module absent' | Out-Null
    return
  }
  if ($script:PcbDryRun) {
    # read-only: show every DRS setting of the plan (all rows of the module's table),
    # never open a write session
    $specs = @()
    if ($null -ne $script:PcbNvLolSettings) { $specs = @($script:PcbNvLolSettings) }
    $planParts = New-Object System.Collections.ArrayList
    foreach ($spec in $specs) { [void]$planParts.Add($spec.Symbol + '=' + [uint32]$spec.Target) }
    $plan = [string]@($specs).Count + ' settings (' + ($planParts -join ' ') + ')'
    $cur = '(unchanged)'
    try {
      if (Get-Command Get-PcbNvLolState -ErrorAction SilentlyContinue) {
        $st = Get-PcbNvLolState
        $parts = New-Object System.Collections.ArrayList
        if ($null -ne $st -and $st.PSObject.Properties['Settings']) {
          foreach ($spec in $specs) {
            $hit = $null
            foreach ($e in @($st.Settings)) { if ($null -ne $e -and [uint32]$e.Id -eq [uint32]$spec.Id) { $hit = $e; break } }
            if ($null -eq $hit) { [void]$parts.Add($spec.Symbol + '=<missing>') } else { [void]$parts.Add($spec.Symbol + '=' + [uint32]$hit.Value) }
          }
          if ($parts.Count -gt 0) { $cur = ($parts -join ' ') }
        }
      }
    } catch { $cur = '(unchanged)' }
    Add-PcbRow 'g' 'nvidia/profile' $cur $plan 'DRYRUN' | Out-Null
    return
  }
  try {
    $r = Set-PcbNvLol
    if ($null -ne $r -and $r.PSObject.Properties['Before']) { $script:PcbState['Nvidia'] = $r.Before }
    Save-PcbState
    $prof = 'n/a'
    if ($null -ne $r -and $r.PSObject.Properties['Before'] -and $null -ne $r.Before) { $prof = [string]$r.Before.Profile }
    if ($null -ne $r -and $r.Ok) {
      Add-PcbRow 'g' 'nvidia/profile' $prof ('applied: ' + $prof) 'OK' | Out-Null
    } else {
      $msg = 'unknown'
      if ($null -ne $r -and $r.PSObject.Properties['Error']) { $msg = [string]$r.Error }
      Add-PcbRow 'g' 'nvidia/profile' $prof 'unchanged' ('FAIL: ' + $msg) | Out-Null
    }
  } catch {
    Add-PcbRow 'g' 'nvidia/profile' 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbNvidia {
  if ($script:PcbDryRun) { return }
  $n = $script:PcbState['Nvidia']
  if ($null -eq $n) { return }
  if (-not (Get-Command Restore-PcbNvLol -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'r' 'nvidia/profile' 'n/a' 'n/a' 'SKIP: nvidia module absent' | Out-Null
    return
  }
  try {
    $r = Restore-PcbNvLol -Before $n
    if ($null -ne $r -and $r.Ok) {
      Add-PcbRow 'r' 'nvidia/profile' '(tuned)' 'restored' 'OK' | Out-Null
    } else {
      $msg = 'unknown'
      if ($null -ne $r -and $r.PSObject.Properties['Error']) { $msg = [string]$r.Error }
      Add-PcbRow 'r' 'nvidia/profile' '(tuned)' 'unknown' ('FAIL: ' + $msg) | Out-Null
    }
  } catch {
    Add-PcbRow 'r' 'nvidia/profile' '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

# ===========================================================================
# step g2 - GPU clocks (module from W-PCB7A, optional)
# ===========================================================================
#
# The home PC raises the power limit and locks the clocks with nvidia-smi.  Everything
# here is read back live with `nvidia-smi --query-gpu`, so a command the driver refused
# is a SKIP row carrying the driver's own words, never a silent OK.

function Invoke-PcbStepGpuClock {
  if (-not (Get-Command Set-PcbGpuClock -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'g' 'gpu/clock' 'n/a' 'n/a' 'SKIP: gpuclock module absent' | Out-Null
    return
  }
  try {
    $st = Get-PcbGpuClockState
    if ($null -eq $st -or -not $st.Available) {
      $msg = 'nvidia-smi not found'
      if ($null -ne $st -and -not [string]::IsNullOrWhiteSpace([string]$st.Error)) { $msg = [string]$st.Error }
      Add-PcbRow 'g' 'gpu/clock' 'n/a' 'n/a' ('SKIP: ' + $msg) | Out-Null
      return
    }
    if ($script:PcbDryRun) {
      $b = $st.Before
      $fmt = [System.Globalization.CultureInfo]::InvariantCulture
      $plan = 'pl=' + [string]::Format($fmt, '{0:0.##}', [double]$b.MaxLimit) + ' lgc=' + [string]::Format($fmt, '{0:0}', [double]$b.MaxGraphics) + ' lmc=' + [string]::Format($fmt, '{0:0}', [double]$b.MaxMemory) + ' ac=' + [string]::Format($fmt, '{0:0}', [double]$b.MaxMemory) + '/' + [string]::Format($fmt, '{0:0}', [double]$b.MaxGraphics)
      $cur = 'pl=' + (Format-PcbNvNum $b.PowerLimit '') + ' gr=' + (Format-PcbNvNum $b.MaxGraphics '')
      Add-PcbRow 'g' 'gpu/clock' $cur $plan 'DRYRUN' | Out-Null
      return
    }
    $r = Set-PcbGpuClock -State $st
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      Add-PcbRow 'g' ([string]$row.Item) $row.Before $row.After ([string]$row.Status) | Out-Null
    }
    if ($null -ne $r.Applied) {
      $a = $r.Applied
      $script:PcbState['GpuClock'] = @{ PowerLimit = $a.PowerLimit; LockedGfx = [bool]$a.LockedGfx; LockedMem = [bool]$a.LockedMem; AppClocks = [bool]$a.AppClocks }
      Save-PcbState
    }
  } catch {
    Add-PcbRow 'g' 'gpu/clock' 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbGpuClockStep {
  if ($script:PcbDryRun) { return }
  $rec = $script:PcbState['GpuClock']
  if ($null -eq $rec) { return }
  if (-not (Get-Command Restore-PcbGpuClock -ErrorAction SilentlyContinue -CommandType Function)) {
    Add-PcbRow 'r' 'gpu/clock' 'n/a' 'n/a' 'SKIP: gpuclock module absent' | Out-Null
    return
  }
  try {
    $r = Restore-PcbGpuClock -Rec $rec
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      Add-PcbRow 'r' ([string]$row.Item) $row.Before $row.After ([string]$row.Status) | Out-Null
    }
  } catch {
    Add-PcbRow 'r' 'gpu/clock' '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

# ===========================================================================
# step d2 - League of Legends config files (module from W-PCB7A, optional)
# ===========================================================================
#
# game.cfg and PersistedSettings.json carry the same latency keys.  Both files are backed
# up into StateDir before the write and restored byte-identically from that backup.

function Invoke-PcbStepLolCfg {
  if (-not (Get-Command Set-PcbLolCfg -ErrorAction SilentlyContinue)) {
    Add-PcbRow 'd2' 'lol/cfg' 'n/a' 'n/a' 'SKIP: lolcfg module absent' | Out-Null
    return
  }
  try {
    $st = Get-PcbLolCfgState
    if ($null -eq $st -or -not [bool]$st.Available) {
      $msg = 'config not found'
      if ($null -ne $st -and -not [string]::IsNullOrWhiteSpace([string]$st.Error)) { $msg = [string]$st.Error }
      Add-PcbRow 'd2' 'lol/cfg' 'n/a' 'n/a' ('SKIP: ' + $msg) | Out-Null
      return
    }
    if ($script:PcbDryRun) {
      foreach ($spec in @($script:PcbLolCfgValues)) {
        $before = '(absent)'
        foreach ($r in @($st.Rows)) {
          if ($null -eq $r) { continue }
          if (([string]$r.Section + '/' + [string]$r.Name) -eq ([string]$spec.Section + '/' + [string]$spec.Name)) { $before = [string]$r.Before }
        }
        Add-PcbRow 'd2' ('lol/' + $spec.Section + '/' + $spec.Name) $before ([string]$spec.Value) 'DRYRUN' | Out-Null
      }
      return
    }
    $r = Set-PcbLolCfg -State $st
    # Restore needs both halves: Backup (where the byte copies are) and Applied (which of
    # them the kit actually rewrote).  Storing Backup alone makes revert skip both files.
    if ($null -ne $r -and $r.PSObject.Properties['Backup']) {
      $script:PcbState['LolCfg'] = [pscustomobject]@{ Backup = $r.Backup; Applied = $r.Applied }
      Save-PcbState
    }
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      Add-PcbRow 'd2' ([string]$row.Item) $row.Before $row.After ([string]$row.Status) | Out-Null
    }
  } catch {
    Add-PcbRow 'd2' 'lol/cfg' 'unknown' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbLolCfgStep {
  if ($script:PcbDryRun) { return }
  $rec = $script:PcbState['LolCfg']
  if ($null -eq $rec) { return }
  if (-not (Get-Command Restore-PcbLolCfg -ErrorAction SilentlyContinue -CommandType Function)) {
    Add-PcbRow 'r' 'lol/cfg' 'n/a' 'n/a' 'SKIP: lolcfg module absent' | Out-Null
    return
  }
  try {
    $r = Restore-PcbLolCfg -Rec $rec
    foreach ($row in @($r.Rows)) {
      if ($null -eq $row) { continue }
      Add-PcbRow 'r' ([string]$row.Item) $row.Before $row.After ([string]$row.Status) | Out-Null
    }
  } catch {
    Add-PcbRow 'r' 'lol/cfg' '(tuned)' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

# ===========================================================================
# step h - watcher
# ===========================================================================

function Write-PcbWLog([string]$Line) {
  try {
    $p = Join-Path $StateDir 'watcher.log'
    Add-Content -LiteralPath $p -Value ((Get-Date -Format s) + ' ' + $Line) -ErrorAction Stop
  } catch { }
}

function Invoke-PcbWatcherLoop {
  $mutex = $null
  try { $mutex = New-Object System.Threading.Mutex($false, 'Global\pcbang-watcher') } catch { $mutex = $null }
  if ($null -ne $mutex) {
    $got = $false
    try { $got = $mutex.WaitOne(0) } catch { $got = $false }
    if (-not $got) { return }
  }
  # The 0.507 ms timer is the core home fix, and a plain process loses it to power
  # throttling.  Opting out of PROCESS_POWER_THROTTLING_EXECUTION_SPEED (and of the
  # timer-resolution ignore) before the request is what makes Windows 11 honour it.
  if (Get-Command Start-PcbTimerHold -ErrorAction SilentlyContinue) {
    try {
      $h = Start-PcbTimerHold -Resolution 5070
      Write-PcbWLog ('timer ' + (Format-PcbTimerMs ([int]$h.Current)) + ' held (asked 5070, min ' + [string]$h.Min + ' max ' + [string]$h.Max + ', throttle-opt-out=' + [string]$h.ThrottleOptOut + ')')
    } catch {
      Write-PcbWLog ('timer hold FAIL ' + $_.Exception.Message)
    }
  } else {
    Write-PcbWLog 'timer module absent'
  }
  $cfg = $null
  $cfgPath = Join-Path $StateDir 'watcher.json'
  if (Test-Path -LiteralPath $cfgPath) {
    try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch { $cfg = $null }
  }
  $gName = $GameName
  $gMask = $GameMask
  $sMask = $SideMask
  $sNames = @($SideNames)
  $pNames = @($ParentNames)
  if ($null -ne $cfg) {
    if ($cfg.PSObject.Properties['GameName']) { $gName = [string]$cfg.GameName }
    if ($cfg.PSObject.Properties['GameMask']) { $gMask = [uint64]$cfg.GameMask }
    if ($cfg.PSObject.Properties['SideMask']) { $sMask = [uint64]$cfg.SideMask }
    if ($cfg.PSObject.Properties['SideNames']) { $sNames = @($cfg.SideNames) }
    if ($cfg.PSObject.Properties['ParentNames']) { $pNames = @($cfg.ParentNames) }
  }
  $gameAff = [IntPtr][int64]$gMask
  $sideAff = [IntPtr][int64]$sMask
  Write-PcbWLog ('watcher start pid ' + $PID + ' game=' + (Format-PcbMask $gMask) + ' side=' + (Format-PcbMask $sMask))
  $seen = @{}
  while ($true) {
    # parents first: the game is born with its parent's affinity, so the launcher has to
    # be on the game mask before it spawns the game.  Priority is left alone here.
    foreach ($q in @(Get-Process -Name $pNames -ErrorAction SilentlyContinue)) {
      if (-not $q) { continue }
      $curAff = $null
      try { $curAff = $q.ProcessorAffinity } catch { continue }
      if ($curAff -eq $gameAff) { continue }
      try {
        $q.ProcessorAffinity = $gameAff
        Write-PcbWLog ('parent pid ' + $q.Id + ' ' + $q.ProcessName + ' aff=' + $q.ProcessorAffinity + ' prio=' + $q.PriorityClass)
      } catch {
        Write-PcbWLog ('parent pid ' + $q.Id + ' ' + $q.ProcessName + ' FAIL ' + $_.Exception.Message)
      }
    }
    $alive = @{}
    foreach ($sp in @(Get-Process -Name $sNames -ErrorAction SilentlyContinue)) {
      if (-not $sp) { continue }
      $alive[[string]$sp.Id] = 1
      $curAff = $null
      $curPrio = $null
      try { $curAff = $sp.ProcessorAffinity; $curPrio = $sp.PriorityClass } catch { continue }
      $affOK = ($curAff -eq $sideAff)
      $prioOK = ($curPrio -eq 'Idle')
      if ($affOK -and $prioOK) { continue }
      try {
        if (-not $affOK) { $sp.ProcessorAffinity = $sideAff }
        if (-not $prioOK) { $sp.PriorityClass = 'Idle' }
        Write-PcbWLog ('side pid ' + $sp.Id + ' ' + $sp.ProcessName + ' aff=' + $sp.ProcessorAffinity + ' prio=' + $sp.PriorityClass)
      } catch {
        Write-PcbWLog ('side pid ' + $sp.Id + ' ' + $sp.ProcessName + ' FAIL ' + $_.Exception.Message)
      }
    }
    foreach ($p in @(Get-Process -Name $gName -ErrorAction SilentlyContinue)) {
      if (-not $p) { continue }
      $alive[[string]$p.Id] = 1
      $curAff = $null
      $curPrio = $null
      try { $curAff = $p.ProcessorAffinity; $curPrio = $p.PriorityClass } catch { continue }
      $affOK = ($curAff -eq $gameAff)
      $prioOK = ($curPrio -eq 'High')
      if ($affOK -and $prioOK) { continue }
      try {
        if (-not $affOK) { $p.ProcessorAffinity = $gameAff }
        if (-not $prioOK) { $p.PriorityClass = 'High' }
        $p.Refresh()
        $key = [string]$p.ProcessorAffinity + '/' + [string]$p.PriorityClass
        if ($seen[[string]$p.Id] -ne $key) {
          Write-PcbWLog ('game pid ' + $p.Id + ' aff=' + $p.ProcessorAffinity + ' prio=' + $p.PriorityClass + ' (applied)')
          $seen[[string]$p.Id] = $key
        }
      } catch {
        Write-PcbWLog ('game pid ' + $p.Id + ' FAIL ' + $_.Exception.Message)
      }
    }
    foreach ($k in @($seen.Keys)) { if (-not $alive[$k]) { $seen.Remove($k) } }
    Start-Sleep -Seconds 2
  }
}

function Invoke-PcbStepWatcher {
  param($Masks)
  if ($NoWatcher) {
    Add-PcbRow 'h' 'watcher' 'n/a' 'n/a' 'SKIP: -NoWatcher' | Out-Null
    Add-PcbRow 'h' 'timer' 'n/a' 'n/a' 'SKIP: needs the watcher' | Out-Null
    return
  }
  if ($script:PcbDryRun) {
    Add-PcbRow 'h' 'watcher' 'not running' ('game=' + (Format-PcbMask $Masks.GameMask) + ' side=' + (Format-PcbMask $Masks.SideMask)) 'DRYRUN' | Out-Null
    Add-PcbRow 'h' 'timer' 'system default' '0.507 ms held' 'DRYRUN' | Out-Null
    return
  }
  $timerBeforeMs = 'n/a'
  if (Get-Command Get-PcbTimerResolution -ErrorAction SilentlyContinue) {
    try {
      $q0 = Get-PcbTimerResolution
      if ($q0.Ok) { $timerBeforeMs = Format-PcbTimerMs ([int]$q0.Current) }
    } catch { }
  }
  try {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $cfg = [pscustomobject]@{
      GameName    = $GameName
      GameMask    = $Masks.GameMask
      SideMask    = $Masks.SideMask
      SideNames   = @($SideNames)
      ParentNames = @($ParentNames)
    }
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'watcher.json'), ($cfg | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    # run the watcher from the local copy when there is one: step c2 restarts the USB
    # controller and a stick the kit was launched from can drop out for a few seconds
    $scriptPath = $PSCommandPath
    if ($null -ne $script:PcbSelfPath -and (Test-Path -LiteralPath $script:PcbSelfPath)) { $scriptPath = $script:PcbSelfPath }
    $argl = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -WatcherLoop -GameMask ' + $Masks.GameMask + ' -SideMask ' + $Masks.SideMask + ' -StateDir "' + $StateDir + '"'
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argl -PassThru -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $StateDir 'watcher.pid') -Value ([string]$p.Id) -Encoding ASCII
    $script:PcbState['Watcher'] = @{ Pid = $p.Id; Game = $Masks.GameMask; Side = $Masks.SideMask }
    Save-PcbState
    Start-Sleep -Milliseconds 600
    $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($alive) {
      Add-PcbRow 'h' 'watcher' 'not running' ('pid ' + $p.Id) 'OK' | Out-Null
    } else {
      Add-PcbRow 'h' 'watcher' 'not running' ('pid ' + $p.Id) 'FAIL: watcher exited immediately' | Out-Null
    }
    # the timer row is only an OK when the system-wide resolution really moved
    $timerAfterMs = 'n/a'
    if (Get-Command Get-PcbTimerResolution -ErrorAction SilentlyContinue) {
      $q1 = $null
      for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 200
        $q1 = Get-PcbTimerResolution
        if ($q1.Ok -and [int]$q1.Current -le 5070 -and [int]$q1.Current -gt 0) { break }
      }
      if ($null -ne $q1 -and $q1.Ok) { $timerAfterMs = Format-PcbTimerMs ([int]$q1.Current) }
      if ($timerAfterMs -ne 'n/a' -and $timerAfterMs -ne '0.000 ms') {
        $st = 'OK'
        if ($timerAfterMs -ne '0.507 ms') { $st = 'OK (written)' }
        Add-PcbRow 'h' 'timer' $timerBeforeMs ($timerAfterMs + ' held') $st | Out-Null
      } else {
        Add-PcbRow 'h' 'timer' $timerBeforeMs 'unreadable' 'FAIL: NtQueryTimerResolution returned nothing' | Out-Null
      }
    } else {
      Add-PcbRow 'h' 'timer' 'n/a' 'n/a' 'SKIP: timer module absent' | Out-Null
    }
  } catch {
    Add-PcbRow 'h' 'watcher' 'not running' 'unknown' ('FAIL: ' + $_.Exception.Message) | Out-Null
  }
}

function Restore-PcbWatcher {
  if ($script:PcbDryRun) { return }
  $w = $script:PcbState['Watcher']
  if ($null -eq $w) { return }
  $pidTxt = $null
  try { $pidTxt = Get-Content -LiteralPath (Join-Path $StateDir 'watcher.pid') -Raw -ErrorAction Stop } catch { $pidTxt = $null }
  $targets = New-Object System.Collections.ArrayList
  $wPid = Get-PcbStateField $w 'Pid'
  if ($null -ne $wPid) { [void]$targets.Add([int]$wPid) }
  if ($pidTxt) {
    $v = 0
    if ([int]::TryParse($pidTxt.Trim(), [ref]$v)) { if (-not $targets.Contains($v)) { [void]$targets.Add($v) } }
  }
  foreach ($t in @($targets)) {
    $proc = Get-Process -Id $t -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
      Add-PcbRow 'r' 'watcher' ('pid ' + $t) 'gone' 'SKIP: already gone' | Out-Null
      continue
    }
    try {
      Stop-Process -Id $t -Force -ErrorAction Stop
      Start-Sleep -Milliseconds 300
      if (Get-Process -Id $t -ErrorAction SilentlyContinue) {
        Add-PcbRow 'r' 'watcher' ('pid ' + $t) 'alive' 'FAIL: still running' | Out-Null
      } else {
        Add-PcbRow 'r' 'watcher' ('pid ' + $t) 'gone' 'OK' | Out-Null
      }
    } catch {
      Add-PcbRow 'r' 'watcher' ('pid ' + $t) 'alive' ('FAIL: ' + $_.Exception.Message) | Out-Null
    }
  }
  $pidFile = Join-Path $StateDir 'watcher.pid'
  if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# power setting table
# ===========================================================================

# -IdleDisable asks for IDLEDISABLE=1 (keep cores out of the idle state through play),
# -NoIdleDisable forces 0, and with neither switch the kit measures (see the guard below)
# because IDLEDISABLE=1 can lower single-core boost on a CPU whose turbo bin depends on
# the number of active cores.  Home runs 1, so 1 is the default the guard starts from.
$script:PcbIdleDisableWant = 1
if ($NoIdleDisable) { $script:PcbIdleDisableWant = 0 }
# -IdleDisable is an explicit order: keep 1 and do not spend time measuring.
$script:PcbIdleDisableGuard = $true
if ($IdleDisable -or $NoIdleDisable) { $script:PcbIdleDisableGuard = $false }

$script:PcbPowerSettings = @(
  @{ Item = 'PROCTHROTTLEMIN';  Sub = 'SUB_PROCESSOR'; Id = 'PROCTHROTTLEMIN';  Want = 100 },
  @{ Item = 'PROCTHROTTLEMAX';  Sub = 'SUB_PROCESSOR'; Id = 'PROCTHROTTLEMAX';  Want = 100 },
  @{ Item = 'CPMINCORES';       Sub = 'SUB_PROCESSOR'; Id = 'CPMINCORES';       Want = 100 },
  @{ Item = 'PERFBOOSTMODE';    Sub = 'SUB_PROCESSOR'; Id = 'be337238-0d82-4146-a960-4f3749d470c7'; Want = 2 },
  @{ Item = 'PERFEPP';          Sub = 'SUB_PROCESSOR'; Id = 'PERFEPP';          Want = 0 },
  # the four hidden processor settings the home scripts write (p41.ps1:3-5, p50.ps1:11-12,
  # p14.ps1:7).  Unhide=1 means a hidden attribute is cleared before the write and put
  # back on revert only if the kit cleared it.
  @{ Item = 'IDLEDEMOTE';       Sub = 'SUB_PROCESSOR'; Id = '4b92d758-5a24-4851-a470-815d78aee119'; Want = 0;   Unhide = 1 },
  @{ Item = 'CPCONCURRENCY';    Sub = 'SUB_PROCESSOR'; Id = '93b8b6dc-0698-4d1c-9ee4-0644e900c85d'; Want = 100; Unhide = 1 },
  @{ Item = 'SHORTSCHEDPOLICY'; Sub = 'SUB_PROCESSOR'; Id = '7b224883-b3cc-4d79-819f-8374152cbe7c'; Want = 1;   Unhide = 1 },
  @{ Item = 'THROTTLING';       Sub = 'SUB_PROCESSOR'; Id = '3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb'; Want = 2;   Unhide = 1 },
  @{ Item = 'IDLEDISABLE';      Sub = 'SUB_PROCESSOR'; Id = 'IDLEDISABLE';      Want = $script:PcbIdleDisableWant },
  @{ Item = 'USB-SelectiveSuspend'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Id = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Want = 0 },
  @{ Item = 'USB3-LinkPowerMgmt';   Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Id = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; Want = 0 },
  @{ Item = 'PCIE-ASPM';        Sub = 'SUB_PCIEXPRESS'; Id = 'ASPM';            Want = 0 },
  @{ Item = 'DISK-IDLE';        Sub = 'SUB_DISK'; Id = 'DISKIDLE';              Want = 0 },
  @{ Item = 'SLEEP-STANDBY';    Sub = 'SUB_SLEEP'; Id = 'STANDBYIDLE';          Want = 0 }
)

# ===========================================================================
# reporting
# ===========================================================================

function Format-PcbCell($Value, [int]$Width) {
  $s = ''
  if ($null -ne $Value) { $s = [string]$Value }
  $s = $s -replace "[`r`n`t]", ' '
  # adapter descriptions can carry non-ASCII text; the console and the report stay 7-bit
  $s = [regex]::Replace($s, '[^\x20-\x7E]', '?')
  if ($s.Length -gt $Width) { $s = $s.Substring(0, $Width - 1) + '~' }
  return $s.PadRight($Width)
}

function Get-PcbReportText {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine((Format-PcbCell 'Step' 4) + ' ' + (Format-PcbCell 'Item' 34) + ' ' + (Format-PcbCell 'Before' 40) + ' ' + (Format-PcbCell 'After' 40) + ' Status')
  [void]$sb.AppendLine(((('-' * 4) + ' ' + ('-' * 34) + ' ' + ('-' * 40) + ' ' + ('-' * 40) + ' ' + ('-' * 40))))
  foreach ($r in $script:PcbRows) {
    [void]$sb.AppendLine((Format-PcbCell $r.Step 4) + ' ' + (Format-PcbCell $r.Item 34) + ' ' + (Format-PcbCell $r.Before 40) + ' ' + (Format-PcbCell $r.After 40) + ' ' + [string]$r.Status)
  }
  return $sb.ToString()
}

function Write-PcbReport {
  $text = Get-PcbReportText
  Write-PcbLine ''
  Write-PcbLine $text
  try {
    # -DryRun writes nothing: it may use a StateDir that is already there (a test hands it
    # one) but it never creates one.  Otherwise a plain `check.ps1` dry run would leave an
    # empty ProgramData\pcbang-tune behind on a PC that was only being inspected.
    if (-not (Test-Path -LiteralPath $StateDir)) {
      if ($script:PcbDryRun) { return }
      New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $hdr = 'pcbang-tune ' + (Get-Date -Format s) + '  mode=' + $script:PcbMode
    $body = @($hdr, '') + @($text -split "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'report.txt'), (($body -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# ===========================================================================
# main
# ===========================================================================

function Invoke-PcbMain {
  $script:PcbDryRun = [bool]$DryRun
  $script:PcbSelfPath = $null
  $script:PcbMode = 'apply'
  if ($Revert) { $script:PcbMode = 'revert' }

  $stateFile = Join-Path $StateDir 'state.json'
  $haveState = Test-Path -LiteralPath $stateFile

  if (-not $Revert) {
    if ($haveState) {
      Write-PcbLine 'already applied, run REVERT first'
      Write-PcbLine ('state file: ' + $stateFile)
      return 1
    }
  } else {
    if (-not $haveState) {
      Write-PcbLine 'nothing to revert (no state.json)'
      return 1
    }
  }

  # A -DryRun writes nothing, so it must not create the state directory either: a plain
  # `check.ps1` on a fresh PC has to leave no ProgramData\pcbang-tune behind.
  if (-not (Test-Path -LiteralPath $StateDir)) {
    if (-not $DryRun) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
  }

  if ($DryRun) {
    $script:PcbState = @{}
  } elseif ($haveState) {
    $obj = $null
    try { $obj = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { $obj = $null }
    $script:PcbState = @{}
    if ($null -ne $obj) {
      foreach ($p in $obj.PSObject.Properties) { $script:PcbState[$p.Name] = $p.Value }
    }
  }

  $masks = Get-PcbMasks

  # Test-only redirect of the LoL cfg step (src\lolcfg.ps1:22 owns the real override).
  # Set before any step runs so both the apply and the revert path see the same dir.
  if (-not [string]::IsNullOrWhiteSpace($LolCfgDir)) {
    $script:PcbLolCfgDir = $LolCfgDir
  }

  if (-not $Revert) {
    # real run only: keep a self copy next to the state so the watcher never depends on
    # the medium the kit was launched from (step c2 can bounce a USB stick off the bus)
    $script:PcbSelfPath = $null
    if (-not $DryRun -and -not $WatcherLoop) {
      try {
        $selfCopy = Join-Path $StateDir 'pcbang.ps1'
        $selfSrc = $PSCommandPath
        if ($selfSrc -and (Test-Path -LiteralPath $selfSrc)) {
          Copy-Item -LiteralPath $selfSrc -Destination $selfCopy -Force -ErrorAction Stop
          if (Test-Path -LiteralPath $selfCopy) { $script:PcbSelfPath = $selfCopy }
        }
      } catch { $script:PcbSelfPath = $null }
    }
    Write-PcbLine ('masks: game=' + (Format-PcbMask $masks.GameMask) + ' side=' + (Format-PcbMask $masks.SideMask) + ' irq=' + (Format-PcbMask $masks.IrqMask))
    Invoke-PcbStepPower -Masks $masks
    Invoke-PcbStepDisplay
    Invoke-PcbStepNic -Masks $masks
    Invoke-PcbStepIrq -Masks $masks
    Invoke-PcbStepRegistry
    Invoke-PcbStepLolCfg
    Invoke-PcbStepMouse
    Invoke-PcbStepServices
    Invoke-PcbStepTasks
    Invoke-PcbStepNvidia
    Invoke-PcbStepGpuClock
    Invoke-PcbStepWatcher -Masks $masks
  } else {
    Restore-PcbWatcher
    Restore-PcbGpuClockStep
    Restore-PcbNvidia
    Restore-PcbTasks
    Restore-PcbServices
    Restore-PcbMouse
    Restore-PcbLolCfgStep
    Restore-PcbRegistry
    Restore-PcbDxPrefs
    Restore-PcbIrq
    # step c applies netsh, then NIC writes, then UDP last; revert goes back the other way
    Restore-PcbNicUdp
    Restore-PcbNic
    Restore-PcbDisplay
    Restore-PcbPower
    $watcherJson = Join-Path $StateDir 'watcher.json'
    if (Test-Path -LiteralPath $watcherJson) { Remove-Item -LiteralPath $watcherJson -Force -ErrorAction SilentlyContinue }
  }

  Write-PcbReport

  if ($Revert) {
    if (-not $DryRun) {
      if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
      Write-PcbLine 'revert complete, state.json removed'
    }
  } else {
    Write-PcbLine 'apply complete'
    # step c pins the input controllers by USB port instance id; a different port is a
    # different device, so the pins have to be redone from a clean state.
    Write-PcbLine 'If you plug the mouse or keyboard into another USB port, run REVERT, then RUN again.'
  }
  # An elevated console closes the moment this script returns, taking the report with
  # it.  Hold the window open unless it is a test (-NoPause) or a background helper.
  if (-not $NoPause -and -not $WatcherLoop -and -not $DotSource) {
    Write-PcbLine ''
    Write-PcbLine 'Press Enter to close'
    try { [void][Console]::In.ReadLine() } catch { }
  }
  return 0
}

# --- entry -----------------------------------------------------------------

if ($DotSource) { return }

Initialize-PcbNative -ErrorAction SilentlyContinue

if ($WatcherLoop) {
  Invoke-PcbWatcherLoop
  return
}

$PcbIsAdmin = $false
try {
  $PcbIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $PcbIsAdmin = $false }

if (-not $PcbIsAdmin -and -not $DryRun) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in @($PSBoundParameters.Keys)) {
    if (@('WatcherLoop','GameMask','SideMask','DotSource','Revert','DryRun') -contains $k) {
      if ($k -eq 'Revert' -or $k -eq 'DryRun') { [void]$parts.Add('-' + $k) }
      continue
    }
    $v = $PSBoundParameters[$k]
    if ($v -is [switch] -or $v -is [bool]) {
      if ($v) { [void]$parts.Add('-' + $k) }
      continue
    }
    if ($v -is [array]) {
      [void]$parts.Add('-' + $k)
      [void]$parts.Add((($v | ForEach-Object { '"' + ([string]$_ -replace '"', '') + '"' }) -join ','))
      continue
    }
    [void]$parts.Add('-' + $k)
    [void]$parts.Add('"' + ([string]$v -replace '"', '') + '"')
  }
  $argLine = ($parts -join ' ')
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, $argLine) | Out-Null
  } catch {
    Write-PcbLine ('elevation failed: ' + $_.Exception.Message)
    exit 1
  }
  exit 0
}

$rc = Invoke-PcbMain
exit $rc