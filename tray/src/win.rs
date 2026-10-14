//! The only Win32 calls the tray makes, after Fathom's `tray.rs`. Each `unsafe` block is a
//! single FFI call with owned, correctly sized out-parameters.

use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForSystem, SetThreadDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage, WM_QUIT,
};
use windows::core::w;

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

/// HKCU `...\Themes\Personalize\SystemUsesLightTheme`: 1 = light taskbar. Unreadable = dark,
/// the Windows 11 default, which takes the white ink.
pub fn taskbar_uses_light_theme() -> bool {
    let mut light = 0u32;
    let mut bytes = size_of::<u32>() as u32;
    // SAFETY: the value pointer targets a live u32 and `bytes` holds its exact size;
    // RRF_RT_REG_DWORD makes the call refuse any value that is not a 4-byte DWORD.
    let read = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some((&raw mut light).cast()),
            Some(&mut bytes),
        )
    };
    read == ERROR_SUCCESS && light != 0
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
