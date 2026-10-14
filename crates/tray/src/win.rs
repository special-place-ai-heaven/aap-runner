//! The only Win32 calls the tray and its windows make, after Fathom's `tray.rs`. Each `unsafe`
//! block is a single FFI call (or a call pair) with owned, correctly sized out-parameters.

use windows::Win32::Foundation::{ERROR_SUCCESS, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows::Win32::System::LibraryLoader::{
    GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::System::SystemInformation::{GetLocalTime, GetSystemTime};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForSystem, SetThreadDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, FindWindowW, GetClassNameW, GetForegroundWindow, IsIconic, MSG, PM_REMOVE,
    PeekMessageW, PostMessageW, SPI_GETCLIENTAREAANIMATION, SPI_GETWORKAREA, SW_RESTORE,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetForegroundWindow, ShowWindow, SystemParametersInfoW,
    TranslateMessage, WM_CLOSE, WM_QUIT,
};
use windows::core::{BOOL, HSTRING, PCSTR, PCWSTR, w};

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
}
