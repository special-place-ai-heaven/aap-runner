//! The only Win32 calls the tray and its windows make, after Fathom's `tray.rs`. Each `unsafe`
//! block is a single FFI call (or a call pair) with owned, correctly sized out-parameters.

use windows::Win32::Foundation::{
    CloseHandle, ERROR_CANCELLED, ERROR_SUCCESS, HLOCAL, HWND, LPARAM, LocalFree, RECT, WPARAM,
};
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows::Win32::Security::Authorization::{
    ConvertSidToStringSidW, GetSecurityInfo, SE_FILE_OBJECT,
};
use windows::Win32::Security::Cryptography::{BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom};
use windows::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, ACL_SIZE_INFORMATION, AclSizeInformation,
    DACL_SECURITY_INFORMATION, GetAce, GetAclInformation, OWNER_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, PSID,
};
use windows::Win32::System::LibraryLoader::{
    GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows::Win32::System::Registry::{
    HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD, RRF_RT_REG_EXPAND_SZ, RRF_RT_REG_SZ,
    RegGetValueW,
};
use windows::Win32::System::SystemInformation::{GetLocalTime, GetSystemTime};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForSystem, SetThreadDpiAwarenessContext,
};
use windows::Win32::UI::Shell::{
    SEE_MASK_FLAG_NO_UI, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, FindWindowW, GetClassNameW, GetForegroundWindow, IsIconic, MSG, PM_REMOVE,
    PeekMessageW, PostMessageW, SPI_GETCLIENTAREAANIMATION, SPI_GETWORKAREA, SW_HIDE, SW_RESTORE,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetForegroundWindow, ShowWindow, SystemParametersInfoW,
    TranslateMessage, WM_CLOSE, WM_QUIT,
};
use windows::core::{BOOL, HSTRING, PCSTR, PCWSTR, PWSTR, w};

/// Drain this thread's message queue (tray-icon's hidden window lives here).
/// Returns `false` once `WM_QUIT` arrives.
pub fn pump_messages() -> bool {
    let mut msg = MSG::default();
    // SAFETY: `msg` is a valid, writable MSG owned by this frame; a null HWND asks for any
    // message on the calling thread. Translate/Dispatch receive the message Peek filled.
    unsafe {
        while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
            if msg.message == WM_QUIT {
                return false;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    true
}

/// HKCU `...\Themes\Personalize\<value>` as a DWORD flag; unreadable = 0 (dark).
fn personalize_flag(value: PCWSTR) -> bool {
    let mut light = 0u32;
    let mut bytes = size_of::<u32>() as u32;
    // SAFETY: the value pointer targets a live u32 and `bytes` holds its exact size;
    // RRF_RT_REG_DWORD makes the call refuse any value that is not a 4-byte DWORD.
    let read = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
            value,
            RRF_RT_REG_DWORD,
            None,
            Some((&raw mut light).cast()),
            Some(&mut bytes),
        )
    };
    read == ERROR_SUCCESS && light != 0
}

/// `SystemUsesLightTheme`: 1 = light taskbar. Unreadable = dark, the Windows 11 default, which
/// takes the white ink.
pub fn taskbar_uses_light_theme() -> bool {
    personalize_flag(w!("SystemUsesLightTheme"))
}

/// `AppsUseLightTheme`: what the dashboard window follows.
pub fn apps_use_light_theme() -> bool {
    personalize_flag(w!("AppsUseLightTheme"))
}

/// The real desktop DPI. Without a manifest Windows reports 96 to an unaware caller, so
/// mark this thread per-monitor v2 aware for the one call, then restore it.
pub fn system_dpi() -> u32 {
    // SAFETY: plain value calls with no pointers; the previous context is restored as returned.
    unsafe {
        let previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let dpi = GetDpiForSystem();
        if !previous.0.is_null() {
            SetThreadDpiAwarenessContext(previous);
        }
        dpi
    }
}

/// Windows "Show animations in Windows" (`SPI_GETCLIENTAREAANIMATION`); unreadable = on.
pub fn animations_enabled() -> bool {
    let mut on = BOOL(1);
    // SAFETY: the out-pointer targets a live BOOL, the type this action writes.
    let ok = unsafe {
        SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some((&raw mut on).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    ok.is_err() || on.as_bool()
}

/// The primary work area (`SPI_GETWORKAREA`) in logical points: `[left, top, right, bottom]`.
pub fn work_area_points() -> Option<[f32; 4]> {
    let mut r = RECT::default();
    // SAFETY: the out-pointer targets a live RECT, the type this action writes; the thread is
    // made per-monitor aware for the call (physical pixels) and restored after.
    let ok = unsafe {
        let previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let ok = SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some((&raw mut r).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        );
        if !previous.0.is_null() {
            SetThreadDpiAwarenessContext(previous);
        }
        ok
    };
    let scale = system_dpi().max(1) as f32 / 96.0;
    ok.ok()
        .map(|()| [r.left, r.top, r.right, r.bottom].map(|v| v as f32 / scale))
}

/// Local time minus UTC, in seconds (whole minutes), as of now.
pub fn local_offset_secs() -> i64 {
    // SAFETY: both calls only return a SYSTEMTIME by value.
    let (l, u) = unsafe { (GetLocalTime(), GetSystemTime()) };
    let minutes =
        |t: &windows::Win32::Foundation::SYSTEMTIME| i64::from(t.wHour) * 60 + i64::from(t.wMinute);
    let day = |t: &windows::Win32::Foundation::SYSTEMTIME| (t.wYear, t.wMonth, t.wDay);
    let shift = match day(&l).cmp(&day(&u)) {
        std::cmp::Ordering::Greater => 1440,
        std::cmp::Ordering::Less => -1440,
        std::cmp::Ordering::Equal => 0,
    };
    (minutes(&l) - minutes(&u) + shift) * 60
}

/// A top-level window by exact title; the value is the HWND as an integer.
pub fn find_window(title: &str) -> Option<isize> {
    // SAFETY: both arguments are valid NUL-terminated wide strings (or null) for the call.
    unsafe { FindWindowW(PCWSTR::null(), &HSTRING::from(title)) }
        .ok()
        .filter(|h| !h.0.is_null())
        .map(|h| h.0 as isize)
}

/// The foreground window, unless it is the taskbar or its overflow (which take the foreground
/// while the tray icon is clicked).
pub fn foreground_app() -> Option<isize> {
    // SAFETY: GetForegroundWindow takes no arguments; GetClassNameW writes at most the
    // buffer's length into a live array.
    unsafe {
        let h = GetForegroundWindow();
        if h.0.is_null() {
            return None;
        }
        let mut class = [0u16; 64];
        let n = GetClassNameW(h, &mut class).max(0) as usize;
        let class = String::from_utf16_lossy(&class[..n]);
        let shell = [
            "Shell_TrayWnd",
            "Shell_SecondaryTrayWnd",
            "NotifyIconOverflowWindow",
            "TopLevelWindowForOverflowXamlIsland",
        ];
        (!shell.contains(&class.as_str())).then_some(h.0 as isize)
    }
}

fn hwnd(h: isize) -> HWND {
    HWND(h as *mut core::ffi::c_void)
}

/// Restore if minimised and bring to the front.
pub fn focus(h: isize) {
    // SAFETY: value calls on a window handle; a stale handle makes them fail harmlessly.
    unsafe {
        if IsIconic(hwnd(h)).as_bool() {
            let _ = ShowWindow(hwnd(h), SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd(h));
    }
}

/// Ask the window to close, as its title-bar button does.
pub fn close(h: isize) {
    // SAFETY: posts a message with no pointers; a stale handle makes it fail harmlessly.
    let _ = unsafe { PostMessageW(Some(hwnd(h)), WM_CLOSE, WPARAM(0), LPARAM(0)) };
}

/// `SetPreferredAppMode` mode 1: dark menus when Windows apps use the dark theme (2 would force
/// dark regardless).
const ALLOW_DARK: i32 = 1;

/// uxtheme's dark-mode exports, which have names only in Microsoft's symbols, so they are taken
/// by ordinal. Undocumented, but stable since Windows 10 1809 (build 17763) and the route other
/// Win32 apps use for dark popup menus:
/// - 104 `RefreshImmersiveColorPolicyState()`: re-read the app theme from the registry.
/// - 133 `AllowDarkModeForWindow(HWND, bool) -> bool`.
/// - 135 `SetPreferredAppMode(int) -> int` (1809 names it `AllowDarkModeForApp(bool)`; 1 = allow
///   for both).
/// - 136 `FlushMenuThemes()`: drop the cached menu theme so the next popup redraws.
#[derive(Clone, Copy)]
pub struct DarkMenus {
    refresh: unsafe extern "system" fn(),
    allow_for_window: unsafe extern "system" fn(HWND, bool) -> bool,
    set_mode: unsafe extern "system" fn(i32) -> i32,
    flush: unsafe extern "system" fn(),
}

type Farproc = unsafe extern "system" fn() -> isize;

impl DarkMenus {
    /// `None` when uxtheme or any of the four ordinals is missing (older Windows).
    pub fn load() -> Option<DarkMenus> {
        // SAFETY: LoadLibraryExW gets a constant NUL-terminated name and only searches System32;
        // the module is never freed, so the pointers stay valid for the process. GetProcAddress
        // takes an ordinal as a pointer-sized integer below 0x10000 (MAKEINTRESOURCEA) and
        // returns null (None) for a missing one. Each transmute only changes the signature of a
        // non-null function pointer to the one listed above for that ordinal.
        unsafe {
            let module =
                LoadLibraryExW(w!("uxtheme.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32).ok()?;
            let ordinal = |n: usize| GetProcAddress(module, PCSTR(n as *const u8));
            Some(DarkMenus {
                refresh: std::mem::transmute::<Farproc, unsafe extern "system" fn()>(ordinal(104)?),
                allow_for_window: std::mem::transmute::<
                    Farproc,
                    unsafe extern "system" fn(HWND, bool) -> bool,
                >(ordinal(133)?),
                set_mode: std::mem::transmute::<Farproc, unsafe extern "system" fn(i32) -> i32>(
                    ordinal(135)?,
                ),
                flush: std::mem::transmute::<Farproc, unsafe extern "system" fn()>(ordinal(136)?),
            })
        }
    }
}

/// Let the tray's popup menu follow the Windows app theme: allow dark mode for the app and for
/// the hidden tray window, re-read the theme, flush the cached menu theme, and set the window's
/// DWM dark attribute to `dark`. Call before the menu is built and again when the theme flips.
/// `api` `None` (exports missing): does nothing and returns `false`.
pub fn apply_dark_menus(api: Option<DarkMenus>, window: Option<isize>, dark: bool) -> bool {
    let Some(api) = api else {
        return false;
    };
    // SAFETY: the pointers come from `DarkMenus::load` with the signatures uxtheme exports at
    // those ordinals (or from test stubs with the same signatures); none takes a pointer other
    // than the HWND, and a stale HWND makes the window calls fail harmlessly.
    unsafe {
        (api.set_mode)(ALLOW_DARK);
        if let Some(h) = window {
            (api.allow_for_window)(hwnd(h), true);
        }
        (api.refresh)();
        (api.flush)();
    }
    if let Some(h) = window {
        let value = BOOL::from(dark);
        // SAFETY: the attribute pointer targets a live BOOL and the size is that of a BOOL,
        // the type DWMWA_USE_IMMERSIVE_DARK_MODE takes.
        let _ = unsafe {
            DwmSetWindowAttribute(
                hwnd(h),
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                (&raw const value).cast(),
                size_of::<BOOL>() as u32,
            )
        };
    }
    true
}

/// 16 lowercase hex digits from the system RNG.
pub fn random_id() -> std::io::Result<String> {
    let mut bytes = [0u8; 8];
    // SAFETY: `bytes` is a live 8-byte buffer. `None` selects the process-wide RNG.
    let status = unsafe { BCryptGenRandom(None, &mut bytes, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status.0 < 0 {
        return Err(std::io::Error::other(format!("rng status {}", status.0)));
    }
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn wide(text: &std::ffi::OsStr) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    text.encode_wide().chain(std::iter::once(0)).collect()
}

/// One UAC prompt. Returns when the elevated process has been created, not when it exits.
/// The caller does not wait on the process.
pub fn shell_execute_runas(exe: &std::path::Path, parameters: &str) -> Result<(), String> {
    let file = wide(exe.as_os_str());
    let params = wide(std::ffi::OsStr::new(parameters));
    let verb = wide(std::ffi::OsStr::new("runas"));
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI,
        lpVerb: PCWSTR::from_raw(verb.as_ptr()),
        lpFile: PCWSTR::from_raw(file.as_ptr()),
        lpParameters: PCWSTR::from_raw(params.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    // SAFETY: the three buffers are null-terminated and live for this call. `cbSize` is the
    // struct's size. Every other pointer stays null from `Default`.
    if let Err(err) = unsafe { ShellExecuteExW(&mut info) } {
        let cancelled = err.code().0 as u32 & 0xFFFF == ERROR_CANCELLED.0;
        return Err(if cancelled {
            "Elevation was declined.".to_string()
        } else {
            format!("Could not start the elevated helper: {err}")
        });
    }
    if !info.hProcess.is_invalid() {
        // SAFETY: `hProcess` is the handle this call just opened.
        let _ = unsafe { CloseHandle(info.hProcess) };
    }
    Ok(())
}

/// One DACL entry. `other` is an ACE that is neither allow nor deny.
#[derive(Clone, Debug)]
pub struct DirectoryAce {
    pub sid: String,
    pub allow: bool,
    pub other: bool,
    pub rights: u32,
    pub inherit_only: bool,
}

/// Owner SID plus the DACL of a file or directory.
#[derive(Clone, Debug)]
pub struct ObjectAcl {
    pub owner: String,
    pub aces: Vec<DirectoryAce>,
}

/// Machine `PSModulePath`, expanded. Empty is an error: an elevated script must not fall
/// back to the caller's module path.
pub fn machine_ps_module_path() -> std::io::Result<String> {
    let mut buf = vec![0u16; 2048];
    let mut byte_len = (buf.len() * 2) as u32;
    // SAFETY: the buffer and length are live. The flags ask for a string and expand REG_EXPAND_SZ.
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            w!(r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
            w!("PSModulePath"),
            RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ,
            None,
            Some(buf.as_mut_ptr().cast()),
            Some(&mut byte_len),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(status.0 as i32));
    }
    let chars = (byte_len as usize / 2).saturating_sub(1);
    let text = String::from_utf16_lossy(&buf[..chars.min(buf.len())]);
    if text.is_empty() {
        return Err(std::io::Error::other("machine PSModulePath is empty"));
    }
    Ok(text)
}

fn owned_acl(owner: PSID, dacl: *mut ACL, sd: PSECURITY_DESCRIPTOR) -> std::io::Result<ObjectAcl> {
    let owner_sid = if owner.0.is_null() {
        String::new()
    } else {
        // SAFETY: the owner SID points into `sd`, which is still allocated.
        match unsafe { psid_text(owner) } {
            Ok(text) => text,
            Err(e) => {
                if !sd.0.is_null() {
                    unsafe {
                        let _ = LocalFree(Some(HLOCAL(sd.0)));
                    }
                }
                return Err(e);
            }
        }
    };
    let aces = read_dacl(dacl);
    if !sd.0.is_null() {
        // SAFETY: this is the descriptor the security call allocated.
        unsafe {
            let _ = LocalFree(Some(HLOCAL(sd.0)));
        }
    }
    Ok(ObjectAcl {
        owner: owner_sid,
        aces: aces?,
    })
}

/// A DOS path on a fixed local disk: `C:\...`, drive type `DRIVE_FIXED`.
/// UNC (`\\server\...`) and a network redirect (`DRIVE_REMOTE`) are refused.
pub fn is_fixed_local_path(path: &std::path::Path) -> bool {
    fixed_local_path(&path.to_string_lossy(), drive_type_of(path))
}

pub fn fixed_local_path(path: &str, drive_type: Option<u32>) -> bool {
    let b = path.as_bytes();
    // Accept plain DOS drive letter: C:\...
    let dos = b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\';
    dos && drive_type == Some(3) // DRIVE_FIXED; DRIVE_REMOTE is 4
}

/// Extract the volume root suitable for `GetDriveTypeW` from any path form:
/// - `C:\x\y.exe` or `\\?\C:\x\y.exe` (defensive) -> `"C:\"`
/// - UNC or unrecognized -> `None`
pub fn drive_root_of(path: &str) -> Option<String> {
    // Strip \\?\ defensively; strip_extended_path should have removed it, but handle it.
    let p = path.strip_prefix(r"\\?\").unwrap_or(path);
    let b = p.as_bytes();
    // DOS drive letter: C:\...
    if b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\' {
        return Some(format!("{}:\\", char::from(b[0]).to_ascii_uppercase()));
    }
    None // UNC or other non-local form
}

pub(crate) fn drive_type_of(path: &std::path::Path) -> Option<u32> {
    let root = drive_root_of(&path.to_string_lossy())?;
    let wide = wide(std::ffi::OsStr::new(&root));
    // SAFETY: `wide` is null-terminated and lives for this call.
    let kind = unsafe {
        windows::Win32::Storage::FileSystem::GetDriveTypeW(PCWSTR::from_raw(wide.as_ptr()))
    };
    Some(kind)
}

/// `\\?\C:\...` from `GetFinalPathNameByHandleW` back to a DOS path.
pub fn strip_extended_path(raw: &str) -> String {
    if let Some(rest) = raw.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    raw.strip_prefix(r"\\?\").unwrap_or(raw).to_string()
}

/// Open `path`, follow links, and return the final DOS path plus the security of that handle.
pub fn resolve_exe(path: &std::path::Path) -> std::io::Result<ResolvedExe> {
    let handle = open_read_control(path, false)?;
    let final_path = final_dos_path(&handle)?;
    let acl = acl_of_handle(&handle)?;
    Ok(ResolvedExe {
        path: std::path::PathBuf::from(final_path),
        acl,
    })
}

/// Security of `path` read from a handle, not from the path string.
pub fn acl_of_path(path: &std::path::Path, directory: bool) -> std::io::Result<ObjectAcl> {
    let handle = open_read_control(path, directory)?;
    acl_of_handle(&handle)
}

pub struct ResolvedExe {
    pub path: std::path::PathBuf,
    pub acl: ObjectAcl,
}

struct Opened(windows::Win32::Foundation::HANDLE);

impl Drop for Opened {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

fn open_read_control(path: &std::path::Path, directory: bool) -> std::io::Result<Opened> {
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_SHARE_DELETE, FILE_SHARE_READ,
        FILE_SHARE_WRITE, OPEN_EXISTING, READ_CONTROL,
    };
    let wide_name = wide(path.as_os_str());
    let flags = if directory {
        FILE_FLAG_BACKUP_SEMANTICS
    } else {
        windows::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL
    };
    // SAFETY: `wide_name` is null-terminated. READ_CONTROL is what GetSecurityInfo requires.
    let handle = unsafe {
        CreateFileW(
            PCWSTR::from_raw(wide_name.as_ptr()),
            READ_CONTROL.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            flags,
            None,
        )
    }
    .map_err(|e| std::io::Error::from_raw_os_error(e.code().0))?;
    Ok(Opened(handle))
}

fn final_dos_path(handle: &Opened) -> std::io::Result<String> {
    use windows::Win32::Storage::FileSystem::{GetFinalPathNameByHandleW, VOLUME_NAME_DOS};
    let mut buf = vec![0u16; 1024];
    // SAFETY: `handle` is open and `buf` is writable for this call.
    let n = unsafe { GetFinalPathNameByHandleW(handle.0, &mut buf, VOLUME_NAME_DOS) };
    if n == 0 || n as usize >= buf.len() {
        return Err(std::io::Error::last_os_error());
    }
    let text = String::from_utf16_lossy(&buf[..n as usize]);
    Ok(strip_extended_path(&text))
}

fn acl_of_handle(handle: &Opened) -> std::io::Result<ObjectAcl> {
    let mut owner = PSID(std::ptr::null_mut());
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut sd = PSECURITY_DESCRIPTOR(std::ptr::null_mut());
    // SAFETY: `handle` is open with READ_CONTROL. The out-pointers are live locals.
    let status = unsafe {
        GetSecurityInfo(
            handle.0,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(std::ptr::addr_of_mut!(dacl)),
            None,
            Some(std::ptr::addr_of_mut!(sd)),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(status.0 as i32));
    }
    owned_acl(owner, dacl, sd)
}

fn read_dacl(dacl: *mut ACL) -> std::io::Result<Vec<DirectoryAce>> {
    if dacl.is_null() {
        return Ok(vec![DirectoryAce {
            sid: "S-1-5-11".to_string(),
            allow: true,
            other: false,
            rights: 0x1000_0000,
            inherit_only: false,
        }]);
    }
    let mut info = ACL_SIZE_INFORMATION::default();
    // SAFETY: `dacl` is the DACL inside the descriptor, still allocated.
    unsafe {
        GetAclInformation(
            dacl,
            (&raw mut info).cast(),
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
    }
    .map_err(|e| std::io::Error::other(e.to_string()))?;
    let mut out = Vec::new();
    for index in 0..info.AceCount {
        let mut ace_ptr: *mut core::ffi::c_void = std::ptr::null_mut();
        // SAFETY: `index` is below AceCount and `dacl` is still live.
        unsafe { GetAce(dacl, index, &mut ace_ptr) }
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        if ace_ptr.is_null() {
            continue;
        }
        // SAFETY: GetAce returned a pointer to an ACE_HEADER inside `dacl`.
        let header = unsafe { &*ace_ptr.cast::<ACE_HEADER>() };
        if header.AceType != 0 && header.AceType != 1 {
            out.push(DirectoryAce {
                sid: String::new(),
                allow: false,
                other: true,
                rights: 0,
                inherit_only: false,
            });
            continue;
        }
        // Allow and deny ACEs share this layout.
        let ace = unsafe { &*ace_ptr.cast::<ACCESS_ALLOWED_ACE>() };
        out.push(DirectoryAce {
            sid: sid_text(ace)?,
            allow: header.AceType == 0,
            other: false,
            rights: ace.Mask,
            inherit_only: header.AceFlags & 8 != 0,
        });
    }
    Ok(out)
}

fn sid_text(ace: &ACCESS_ALLOWED_ACE) -> std::io::Result<String> {
    let sid = PSID(std::ptr::addr_of!(ace.SidStart).cast_mut().cast());
    // SAFETY: `sid` points at the SID embedded in this ACE. The caller still owns the ACL.
    unsafe { psid_text(sid) }
}

unsafe fn psid_text(sid: PSID) -> std::io::Result<String> {
    let mut name = PWSTR(std::ptr::null_mut());
    // SAFETY: `sid` is a SID the caller still owns. `name` is an out-pointer.
    unsafe { ConvertSidToStringSidW(sid, &mut name) }
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let text = if name.0.is_null() {
        String::new()
    } else {
        // SAFETY: ConvertSidToStringSid wrote a null-terminated LocalAlloc string.
        unsafe {
            let mut len = 0usize;
            while len < 184 && *name.0.add(len) != 0 {
                len += 1;
            }
            String::from_utf16_lossy(std::slice::from_raw_parts(name.0, len))
        }
    };
    if !name.0.is_null() {
        // SAFETY: the string was allocated by ConvertSidToStringSid.
        unsafe {
            let _ = LocalFree(Some(HLOCAL(name.0.cast())));
        }
    }
    if text.is_empty() {
        return Err(std::io::Error::other("empty sid"));
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI32, Ordering};

    static MODE: AtomicI32 = AtomicI32::new(-1);
    static FLUSHES: AtomicI32 = AtomicI32::new(0);
    static REFRESHES: AtomicI32 = AtomicI32::new(0);

    unsafe extern "system" fn refresh() {
        REFRESHES.fetch_add(1, Ordering::SeqCst);
    }
    unsafe extern "system" fn allow(_: HWND, _: bool) -> bool {
        true
    }
    unsafe extern "system" fn set_mode(mode: i32) -> i32 {
        MODE.swap(mode, Ordering::SeqCst)
    }
    unsafe extern "system" fn flush() {
        FLUSHES.fetch_add(1, Ordering::SeqCst);
    }

    #[test]
    fn dark_menus_are_a_no_op_without_the_exports() {
        assert!(!apply_dark_menus(None, None, true));
        assert_eq!(MODE.load(Ordering::SeqCst), -1, "nothing was called");
        assert_eq!(FLUSHES.load(Ordering::SeqCst), 0);
        let stub = DarkMenus {
            refresh,
            allow_for_window: allow,
            set_mode,
            flush,
        };
        assert!(apply_dark_menus(Some(stub), None, true));
        assert_eq!(MODE.load(Ordering::SeqCst), ALLOW_DARK);
        assert_eq!(REFRESHES.load(Ordering::SeqCst), 1);
        assert_eq!(FLUSHES.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_file_opened_through_a_junction_resolves_to_the_target() {
        let root = std::env::temp_dir().join(format!("aap-final-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let target = root.join("target");
        let link = root.join("link");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("tray.exe"), b"x").unwrap();
        let status = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
            .args([
                "/d",
                "/c",
                "mklink",
                "/J",
                &link.display().to_string(),
                &target.display().to_string(),
            ])
            .status()
            .unwrap();
        assert!(status.success(), "mklink failed");
        let resolved = resolve_exe(&link.join("tray.exe")).unwrap();
        let text = resolved.path.to_string_lossy().to_ascii_lowercase();
        assert!(text.contains(r"\target\tray.exe"), "{text}");
        assert!(!text.contains(r"\link\"), "{text}");
        let _ = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
            .args(["/d", "/c", "rmdir", &link.display().to_string()])
            .status();
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn extended_dos_prefixes_come_off() {
        assert_eq!(
            strip_extended_path(r"\\?\C:\Program Files\tray.exe"),
            r"C:\Program Files\tray.exe"
        );
        assert_eq!(
            strip_extended_path(r"\\?\UNC\server\share\tray.exe"),
            r"\\server\share\tray.exe"
        );
        assert_eq!(strip_extended_path(r"C:\plain.exe"), r"C:\plain.exe");
        assert!(fixed_local_path(r"C:\Windows\notepad.exe", Some(3)));
        assert!(!fixed_local_path(r"Z:\tray.exe", Some(4)), "mapped drive");
        assert!(!fixed_local_path(r"\\server\share\tray.exe", Some(3)));
        assert!(!fixed_local_path(r"C:notepad.exe", Some(3)));
        assert!(is_fixed_local_path(std::path::Path::new(
            r"C:\Windows\notepad.exe"
        )));
    }

    #[test]
    fn drive_root_of_handles_all_forms() {
        // Plain DOS drive letter
        assert_eq!(drive_root_of(r"C:\x\y.exe"), Some("C:\\".into()));
        assert_eq!(drive_root_of(r"D:\foo.exe"), Some("D:\\".into()));
        // Extended prefix (defensive; strip_extended_path should remove it first)
        assert_eq!(drive_root_of(r"\\?\C:\x\y.exe"), Some("C:\\".into()));
        // UNC returns None
        assert_eq!(drive_root_of(r"\\server\share\exe"), None);
        assert_eq!(drive_root_of(r"\\?\UNC\server\share\exe"), None);
    }

    #[test]
    fn current_exe_is_on_fixed_local_drive() {
        let exe = std::env::current_exe().expect("current_exe");
        let resolved = resolve_exe(&exe).expect("resolve_exe");
        assert!(
            is_fixed_local_path(&resolved.path),
            "resolved path '{}' must be on a fixed local drive",
            resolved.path.display()
        );
    }
}
