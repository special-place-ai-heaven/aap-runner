//! `--helper update`: replace the installed tray with a build the owner picked.
//!
//! Everything in the request is user-controlled (the inbox is user-writable), the candidate
//! path and the expected sha256 included. So the helper copies the candidate into an admin-only
//! staging folder first and checks only that copy: [`verify_staged`] takes the staged path and
//! nothing else, so the user's file can change after the copy without changing the verdict.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

pub const INSTALL_DIR: &str = r"C:\Program Files\aap-runner";
pub const TRAY_NAME: &str = "aap-runner-tray.exe";
/// `ProductName` in `assets/aap-runner-tray.rc`; `OriginalFilename` is [`TRAY_NAME`].
pub const PRODUCT: &str = "aap-runner-tray";
/// A release tray is about 10 MiB; this bounds what an elevated copy can write.
pub const MAX_EXE: u64 = 64 * 1024 * 1024;
/// How long the swap retries the first rename (the tray quitting, AV holding the file).
pub const RENAME_WAIT: Duration = Duration::from_secs(30);

const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
const FILE_SHARE_READ: u32 = 0x1;
const REPARSE: u32 = 0x400;

/// 64 lowercase hex digits.
pub fn sha_ok(sha: &str) -> bool {
    sha.len() == 64 && sha.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A plain `X:\...\name.exe` under 1 KiB: no UNC, `\\?\` or `\\.\` prefix, no `:` after the
/// drive (so no alternate data stream), no `..`, no empty or trailing-dot/space component, and
/// no DOS device name. [`copy_candidate`] then checks the opened handle itself.
pub fn check_path(path: &str) -> Result<(), String> {
    const BAD: &str = "candidate must be a plain local path like C:\\...\\aap-runner-tray.exe (letters, digits, space, _ . - only)";
    if path.len() > 1024 || !crate::helper::exe_ok(path) {
        return Err(BAD.into());
    }
    for part in path[3..].split('\\') {
        if part.is_empty() || part.ends_with(['.', ' ']) {
            return Err(BAD.into());
        }
        let stem = part
            .split('.')
            .next()
            .unwrap_or("")
            .trim_end()
            .to_ascii_lowercase();
        let numbered = |p: &str| {
            stem.strip_prefix(p)
                .is_some_and(|n| n.len() == 1 && n.as_bytes()[0].is_ascii_digit())
        };
        if matches!(stem.as_str(), "con" | "prn" | "aux" | "nul")
            || numbered("com")
            || numbered("lpt")
        {
            return Err("candidate path names a device".into());
        }
    }
    Ok(())
}

pub fn installed_path(install_dir: &Path) -> PathBuf {
    install_dir.join(TRAY_NAME)
}

/// The helper replaces only `<install_dir>\aap-runner-tray.exe`, and only when it is running from
/// exactly that file (`self_path` is the handle-resolved path of the running helper).
pub fn check_self(self_path: &Path, install_dir: &Path) -> Result<PathBuf, String> {
    let installed = installed_path(install_dir);
    if self_path
        .to_string_lossy()
        .eq_ignore_ascii_case(&installed.to_string_lossy())
    {
        Ok(installed)
    } else {
        Err(format!(
            "update runs only from the installed tray {}; this one is {}",
            installed.display(),
            self_path.display()
        ))
    }
}

/// Open the candidate once, without following a link, and check that handle: a regular file,
/// not a reparse point, one hard link, 1 byte to [`MAX_EXE`], final path equal to the requested
/// path on a fixed local drive (so no 8.3 alias or normalisation), and then `location` on the
/// handle's ACL and folder. Production passes [`private_location`]. Returns the handle and size.
pub fn open_candidate(
    source: &str,
    location: impl FnOnce(crate::win::ObjectAcl, &Path) -> Result<(), String>,
) -> Result<(File, u64), String> {
    check_path(source)?;
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(source)
        .map_err(|e| format!("could not open the candidate: {e}"))?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if meta.file_attributes() & REPARSE != 0 {
        return Err("candidate is a link or junction".into());
    }
    if !meta.is_file() {
        return Err("candidate is not a regular file".into());
    }
    if meta.len() == 0 || meta.len() > MAX_EXE {
        return Err(format!(
            "candidate is {} bytes; expected 1 to {MAX_EXE}",
            meta.len()
        ));
    }
    if crate::win::link_count(&file).map_err(|e| e.to_string())? != 1 {
        return Err("candidate has more than one hard link".into());
    }
    let final_path = crate::win::final_path_of(&file).map_err(|e| e.to_string())?;
    if !final_path.eq_ignore_ascii_case(source)
        || !crate::win::is_fixed_local_path(Path::new(&final_path))
    {
        return Err(format!(
            "candidate resolves to {final_path}, not the same plain path on a fixed local drive"
        ));
    }
    let acl = crate::win::acl_of_file(&file).map_err(|e| e.to_string())?;
    let dir = Path::new(&final_path)
        .parent()
        .ok_or("candidate has no folder")?;
    location(acl, dir)?;
    Ok((file, meta.len()))
}

/// The installer's location rule for `user` (the process user): the file is owned by `user` or
/// Administrators and no other account can write it, write its folder, or replace an ancestor.
pub fn private_location(
    user: &str,
) -> impl FnOnce(crate::win::ObjectAcl, &Path) -> Result<(), String> + '_ {
    move |acl, dir| crate::helper::user_location_ok(acl, dir, user)
}

/// Copy the candidate checked by [`open_candidate`] into `staged` (create-new) from that handle.
pub fn copy_candidate(
    source: &str,
    staged: &Path,
    location: impl FnOnce(crate::win::ObjectAcl, &Path) -> Result<(), String>,
) -> Result<(), String> {
    let (mut file, _) = open_candidate(source, location)?;
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(staged)
        .map_err(|e| format!("could not create the staged copy: {e}"))?;
    let copied = io::copy(&mut (&mut file).take(MAX_EXE + 1), &mut out)
        .map_err(|e| e.to_string())
        .and_then(|n| {
            if n == 0 || n > MAX_EXE {
                Err("candidate changed size while it was copied".to_string())
            } else {
                out.sync_all().map_err(|e| e.to_string())
            }
        });
    if let Err(e) = copied {
        drop(out);
        let _ = fs::remove_file(staged);
        return Err(e);
    }
    Ok(())
}

/// Hash and inspect the staged copy only. Its FILEVERSION must not be lower than `installed`
/// (0 when the installed build has none). Returns its sha256.
pub fn verify_staged(staged: &Path, expected: &str, installed: u64) -> Result<String, String> {
    let bytes = read_capped(staged)?;
    let actual = hex(&crate::win::sha256(&bytes).map_err(|e| e.to_string())?);
    // The step text lands in status.json, which every user can read: name only the request's hash.
    if actual != expected {
        return Err(format!(
            "sha256 mismatch: the staged copy is not the build with sha256 {expected}"
        ));
    }
    let version = check_image(&bytes)?;
    if version < installed {
        return Err(format!(
            "candidate version {} is older than the installed {}",
            dotted(version),
            dotted(installed)
        ));
    }
    Ok(actual)
}

/// An x64 PE32+ executable (not a DLL) whose version resource says `ProductName`
/// [`PRODUCT`] and `OriginalFilename` [`TRAY_NAME`]. A sanity check against the wrong file,
/// not a trust check: anyone can write those strings; the sha256 binds the owner's pick.
/// Returns FILEVERSION as `major << 48 | minor << 32 | patch << 16 | build`.
pub fn check_image(bytes: &[u8]) -> Result<u64, String> {
    image_problem(bytes).map_err(|e| format!("candidate refused: {e}"))
}

/// FILEVERSION of the installed tray, 0 when it predates the version resource.
pub fn installed_version(bytes: &[u8]) -> u64 {
    check_image(bytes).unwrap_or(0)
}

/// [`installed_version`] of the file at `path` (admin-only; a read error refuses the update).
pub fn installed_version_of(path: &Path) -> Result<u64, String> {
    read_capped(path).map(|b| installed_version(&b))
}

fn dotted(v: u64) -> String {
    format!(
        "{}.{}.{}.{}",
        v >> 48,
        (v >> 32) & 0xffff,
        (v >> 16) & 0xffff,
        v & 0xffff
    )
}

/// What the elevated confirmation box says.
pub fn confirm_text(path: &str, size: u64, sha: &str) -> String {
    format!(
        "Replace the installed AAP Runner tray with this build?\n\n{path}\n{size} bytes\nsha256 {sha}\n\nCompare the sha256 with the build you made. Only Yes installs it."
    )
}

pub fn prev_path(installed: &Path) -> PathBuf {
    let mut prev = installed.as_os_str().to_owned();
    prev.push(".prev");
    PathBuf::from(prev)
}

/// Delete the build a previous update kept. `true` when one was removed; a `.prev` that is
/// still running (an old window) stays until the next try.
pub fn remove_prev(installed: &Path) -> bool {
    let prev = prev_path(installed);
    fs::symlink_metadata(&prev).is_ok_and(|m| m.is_file()) && fs::remove_file(&prev).is_ok()
}

fn image_problem(b: &[u8]) -> Result<u64, &'static str> {
    const BAD: &str = "not a PE image";
    const NOT_TRAY: &str = "its version resource does not name aap-runner-tray";
    if b.get(0..2) != Some(b"MZ") {
        return Err(BAD);
    }
    let pe = u32_at(b, 0x3c).ok_or(BAD)? as usize;
    if b.get(pe..pe + 4) != Some(b"PE\0\0") {
        return Err(BAD);
    }
    if u16_at(b, pe + 4).ok_or(BAD)? != 0x8664 {
        return Err("not an x64 image");
    }
    let sections = u16_at(b, pe + 6).ok_or(BAD)? as usize;
    let opt_size = u16_at(b, pe + 20).ok_or(BAD)? as usize;
    let characteristics = u16_at(b, pe + 22).ok_or(BAD)?;
    // IMAGE_FILE_EXECUTABLE_IMAGE set, IMAGE_FILE_DLL clear.
    if characteristics & 0x0002 == 0 || characteristics & 0x2000 != 0 {
        return Err("not an executable image");
    }
    let opt = pe + 24;
    if u16_at(b, opt).ok_or(BAD)? != 0x20b {
        return Err("not a PE32+ image");
    }
    if opt_size < 112 + 24 || u32_at(b, opt + 108).ok_or(BAD)? < 3 {
        return Err("no resource directory");
    }
    let rsrc_rva = u32_at(b, opt + 112 + 16).ok_or(BAD)?;
    if rsrc_rva == 0 {
        return Err("no resource directory");
    }
    let table = opt + opt_size;
    let file_offset = |rva: u32| -> Option<usize> {
        (0..sections).find_map(|i| {
            let s = table + i * 40;
            let size = u32_at(b, s + 8)?.max(u32_at(b, s + 16)?);
            let va = u32_at(b, s + 12)?;
            let raw = u32_at(b, s + 20)? as usize;
            (rva >= va && rva - va < size).then(|| raw + (rva - va) as usize)
        })
    };
    let root = file_offset(rsrc_rva).ok_or(BAD)?;
    // One IMAGE_RESOURCE_DIRECTORY: the entry for `want` (any entry when `None`).
    let entry = |dir: usize, want: Option<u32>| -> Option<u32> {
        let count = u16_at(b, dir + 12)? as usize + u16_at(b, dir + 14)? as usize;
        (0..count).find_map(|i| {
            let e = dir + 16 + i * 8;
            let name = u32_at(b, e)?;
            want.is_none_or(|w| w == name)
                .then(|| u32_at(b, e + 4))
                .flatten()
        })
    };
    const SUBDIR: u32 = 0x8000_0000;
    // RT_VERSION (16) -> first name -> first language -> IMAGE_RESOURCE_DATA_ENTRY.
    let by_type = entry(root, Some(16)).ok_or(NOT_TRAY)?;
    let by_name = (by_type & SUBDIR != 0)
        .then(|| entry(root + (by_type & !SUBDIR) as usize, None))
        .flatten()
        .ok_or(BAD)?;
    let data = (by_name & SUBDIR != 0)
        .then(|| entry(root + (by_name & !SUBDIR) as usize, None))
        .flatten()
        .filter(|d| d & SUBDIR == 0)
        .ok_or(BAD)?;
    let data = root + data as usize;
    let start = file_offset(u32_at(b, data).ok_or(BAD)?).ok_or(BAD)?;
    let len = u32_at(b, data + 4).ok_or(BAD)? as usize;
    let blob = b
        .get(start..start.checked_add(len).ok_or(BAD)?)
        .ok_or(BAD)?;
    let (version, strings) = version_strings(blob).ok_or(BAD)?;
    let value = |key: &str| {
        strings
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    };
    if value("ProductName") == Some(PRODUCT) && value("OriginalFilename") == Some(TRAY_NAME) {
        version.ok_or("its version resource has no FILEVERSION")
    } else {
        Err(NOT_TRAY)
    }
}

fn u16_at(b: &[u8], at: usize) -> Option<u16> {
    b.get(at..at.checked_add(2)?)
        .map(|s| u16::from_le_bytes([s[0], s[1]]))
}

fn u32_at(b: &[u8], at: usize) -> Option<u32> {
    b.get(at..at.checked_add(4)?)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn align4(n: usize) -> usize {
    n.next_multiple_of(4)
}

/// A NUL-terminated UTF-16 string at `at` that ends before `end`, and the offset after its NUL.
fn utf16z_at(b: &[u8], mut at: usize, end: usize) -> Option<(String, usize)> {
    let mut units = Vec::new();
    loop {
        if at + 2 > end {
            return None;
        }
        let unit = u16_at(b, at)?;
        at += 2;
        if unit == 0 {
            return Some((String::from_utf16(&units).ok()?, at));
        }
        units.push(unit);
    }
}

/// One version-resource node at `at`: `(key, aligned offset after the key, wValueLength, end)`.
fn vnode(b: &[u8], at: usize) -> Option<(String, usize, usize, usize)> {
    let len = u16_at(b, at)? as usize;
    let end = at.checked_add(len)?;
    if len < 6 || end > b.len() {
        return None;
    }
    let value_len = u16_at(b, at + 2)? as usize;
    let (key, after) = utf16z_at(b, at + 6, end)?;
    Some((key, align4(after), value_len, end))
}

fn kids(b: &[u8], from: usize, end: usize) -> Option<Vec<(String, usize, usize, usize)>> {
    let mut out = Vec::new();
    let mut at = align4(from);
    while at + 6 <= end {
        let node = vnode(b, at)?;
        if node.3 > end {
            return None;
        }
        at = align4(node.3);
        out.push(node);
    }
    Some(out)
}

/// FILEVERSION (from `VS_FIXEDFILEINFO`, when its signature is right) and every
/// `StringFileInfo` key/value in a `VS_VERSIONINFO` blob.
#[allow(clippy::type_complexity)]
fn version_strings(b: &[u8]) -> Option<(Option<u64>, Vec<(String, String)>)> {
    let (key, value, value_len, end) = vnode(b, 0)?;
    if key != "VS_VERSION_INFO" {
        return None;
    }
    let version = (value_len >= 52 && u32_at(b, value) == Some(0xFEEF_04BD))
        .then(|| Some((u64::from(u32_at(b, value + 8)?) << 32) | u64::from(u32_at(b, value + 12)?)))
        .flatten();
    let mut out = Vec::new();
    for (info, info_value, _, info_end) in kids(b, value + value_len, end)? {
        if info != "StringFileInfo" {
            continue;
        }
        for (_, table_value, _, table_end) in kids(b, info_value, info_end)? {
            for (k, v, _, string_end) in kids(b, table_value, table_end)? {
                let text = utf16z_at(b, v, string_end).map(|(s, _)| s);
                out.push((k, text.unwrap_or_default()));
            }
        }
    }
    Some((version, out))
}

/// Move `installed` to `installed.prev` (retrying for `wait`) and `staged` into its place. A
/// stale `.prev` is removed first; if that fails nothing is touched. If the move-in fails the
/// old build is renamed back. Windows renames a running image, so a tray that has not quit yet
/// keeps running from `.prev`.
pub fn swap_in(staged: &Path, installed: &Path, wait: Duration) -> Result<(), String> {
    let prev = prev_path(installed);
    if fs::symlink_metadata(&prev).is_ok() {
        fs::remove_file(&prev).map_err(|e| {
            format!(
                "could not remove the previous build {} ({e}); close every AAP Runner window and retry",
                prev.display()
            )
        })?;
    }
    let deadline = Instant::now() + wait;
    loop {
        match fs::rename(installed, &prev) {
            Ok(()) => break,
            Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(500)),
            Err(e) => return Err(format!("could not move the installed tray aside: {e}")),
        }
    }
    if let Err(e) = fs::rename(staged, installed) {
        return Err(match fs::rename(&prev, installed) {
            Ok(()) => format!("could not move the new build in ({e}); the old build was restored"),
            Err(r) => format!(
                "could not move the new build in ({e}) or restore the old build ({r}); it is at {}",
                prev.display()
            ),
        });
    }
    Ok(())
}

/// The tray side: hash the picked file for the request. The helper does not trust this value
/// beyond comparing it with its own copy.
pub fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = read_capped(path)?;
    crate::win::sha256(&bytes)
        .map(|h| hex(&h))
        .map_err(|e| e.to_string())
}

fn read_capped(path: &Path) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    File::open(path)
        .and_then(|f| f.take(MAX_EXE + 1).read_to_end(&mut bytes))
        .map_err(|e| format!("could not read {}: {e}", path.display()))?;
    if bytes.len() as u64 > MAX_EXE {
        return Err(format!("{} is over {MAX_EXE} bytes", path.display()));
    }
    Ok(bytes)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "aap-update-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        // The long name, as GetFinalPathNameByHandleW reports it: a hosted runner's TEMP is
        // `C:\Users\RUNNER~1\...`, which check_path refuses and no final path equals.
        let long = fs::canonicalize(&dir).unwrap();
        PathBuf::from(crate::win::strip_extended_path(&long.to_string_lossy()))
    }

    fn user() -> String {
        crate::win::current_user_sid().unwrap()
    }

    /// For tests about copying and hashing: this machine's temp folder may itself be shared
    /// (it is on the owner's PC), which the real rule rightly refuses.
    fn anywhere(_: crate::win::ObjectAcl, _: &Path) -> Result<(), String> {
        Ok(())
    }

    /// `icacls <path> /grant <ace>`, no console window.
    fn grant(path: &Path, ace: &str) {
        icacls(path, &["/grant", ace]);
    }

    /// Only the test user, SYSTEM and Administrators, nothing inherited.
    fn make_private(path: &Path) {
        let me = format!("*{}:(F)", user());
        icacls(
            path,
            &[
                "/inheritance:r",
                "/grant:r",
                &me,
                "*S-1-5-18:(F)",
                "*S-1-5-32-544:(F)",
            ],
        );
    }

    fn icacls(path: &Path, args: &[&str]) {
        use std::os::windows::process::CommandExt;
        let ace = args.join(" ");
        let ok = std::process::Command::new(r"C:\Windows\System32\icacls.exe")
            .arg(path)
            .args(args)
            .stdout(std::process::Stdio::null())
            .creation_flags(0x0800_0000)
            .status()
            .unwrap()
            .success();
        assert!(ok, "icacls {ace}");
    }

    fn sha_of(bytes: &[u8]) -> String {
        hex(&crate::win::sha256(bytes).unwrap())
    }

    fn utf16z(s: &str) -> Vec<u8> {
        s.encode_utf16()
            .chain(std::iter::once(0))
            .flat_map(u16::to_le_bytes)
            .collect()
    }

    fn pad4(v: &mut Vec<u8>) {
        while !v.len().is_multiple_of(4) {
            v.push(0);
        }
    }

    /// One version-resource node: header, key, padding, value, padding, children.
    fn vnode(key: &str, kind: u16, value: &[u8], value_len: u16, children: &[Vec<u8>]) -> Vec<u8> {
        let mut v = vec![0, 0];
        v.extend(value_len.to_le_bytes());
        v.extend(kind.to_le_bytes());
        v.extend(utf16z(key));
        pad4(&mut v);
        v.extend(value);
        for child in children {
            pad4(&mut v);
            v.extend(child);
        }
        let len = v.len() as u16;
        v[0..2].copy_from_slice(&len.to_le_bytes());
        v
    }

    const V050: u64 = 5 << 32;

    fn version_blob(product: &str, original: &str) -> Vec<u8> {
        version_blob_at(product, original, V050)
    }

    fn version_blob_at(product: &str, original: &str, version: u64) -> Vec<u8> {
        let string = |k: &str, val: &str| {
            let text = utf16z(val);
            vnode(k, 1, &text, (text.len() / 2) as u16, &[])
        };
        let table = vnode(
            "040904B0",
            1,
            &[],
            0,
            &[
                string("FileDescription", "AAP Runner tray"),
                string("ProductName", product),
                string("OriginalFilename", original),
            ],
        );
        let sfi = vnode("StringFileInfo", 1, &[], 0, &[table]);
        let mut fixed = vec![0u8; 52];
        fixed[0..4].copy_from_slice(&0xFEEF_04BDu32.to_le_bytes());
        fixed[8..12].copy_from_slice(&((version >> 32) as u32).to_le_bytes());
        fixed[12..16].copy_from_slice(&(version as u32).to_le_bytes());
        vnode("VS_VERSION_INFO", 0, &fixed, 52, &[sfi])
    }

    fn put16(v: &mut [u8], at: usize, x: u16) {
        v[at..at + 2].copy_from_slice(&x.to_le_bytes());
    }

    fn put32(v: &mut [u8], at: usize, x: u32) {
        v[at..at + 4].copy_from_slice(&x.to_le_bytes());
    }

    /// A minimal PE32+ with one `.rsrc` section holding RT_VERSION/1/0x409 = `blob`.
    fn pe(machine: u16, blob: &[u8]) -> Vec<u8> {
        const RVA: u32 = 0x1000;
        const RAW: usize = 0x200;
        let mut rsrc = vec![0u8; 0x58];
        let dir = |r: &mut Vec<u8>, at: usize, name: u32, off: u32| {
            put16(r, at + 14, 1);
            put32(r, at + 16, name);
            put32(r, at + 20, off);
        };
        dir(&mut rsrc, 0, 16, 0x8000_0018);
        dir(&mut rsrc, 0x18, 1, 0x8000_0030);
        dir(&mut rsrc, 0x30, 0x409, 0x48);
        put32(&mut rsrc, 0x48, RVA + 0x58);
        put32(&mut rsrc, 0x4c, blob.len() as u32);
        rsrc.extend(blob);
        let mut v = vec![0u8; RAW];
        v[0] = b'M';
        v[1] = b'Z';
        put32(&mut v, 0x3c, 0x40);
        v[0x40..0x44].copy_from_slice(b"PE\0\0");
        put16(&mut v, 0x44, machine);
        put16(&mut v, 0x46, 1);
        put16(&mut v, 0x54, 240);
        put16(&mut v, 0x56, 0x0022);
        let opt = 0x58;
        put16(&mut v, opt, 0x20b);
        put32(&mut v, opt + 108, 16);
        put32(&mut v, opt + 112 + 16, RVA);
        put32(&mut v, opt + 112 + 20, rsrc.len() as u32);
        let sec = opt + 240;
        v[sec..sec + 5].copy_from_slice(b".rsrc");
        put32(&mut v, sec + 8, rsrc.len() as u32);
        put32(&mut v, sec + 12, RVA);
        put32(&mut v, sec + 16, rsrc.len() as u32);
        put32(&mut v, sec + 20, RAW as u32);
        v.extend(rsrc);
        v
    }

    fn good_pe() -> Vec<u8> {
        pe(0x8664, &version_blob(PRODUCT, TRAY_NAME))
    }

    #[test]
    fn sha256_matches_the_standard_vector() {
        assert_eq!(
            sha_of(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn the_expected_sha256_is_64_lowercase_hex() {
        assert!(sha_ok(&"a".repeat(64)));
        assert!(sha_ok(&sha_of(b"x")));
        assert!(!sha_ok(&"A".repeat(64)), "uppercase");
        assert!(!sha_ok(&"a".repeat(63)));
        assert!(!sha_ok(&"a".repeat(65)));
        assert!(!sha_ok(&format!("{}g", "a".repeat(63))));
        assert!(!sha_ok(""));
    }

    #[test]
    fn candidate_paths_are_plain_absolute_local_exe_paths() {
        assert!(check_path(r"C:\Users\me\Downloads\aap-runner-tray.exe").is_ok());
        assert!(check_path(r"D:\build\target\release\aap-runner-tray.exe").is_ok());
        for bad in [
            "",
            r"aap-runner-tray.exe",
            r"\Users\me\aap-runner-tray.exe",
            r"\\server\share\aap-runner-tray.exe",
            r"\\?\C:\Users\me\aap-runner-tray.exe",
            r"\\.\C:\Users\me\aap-runner-tray.exe",
            r"C:\Users\me\aap-runner-tray.exe:evil",
            r"C:\Users\me\a.exe:stream.exe",
            r"C:\Users\..\aap-runner-tray.exe",
            r"C:/Users/me/aap-runner-tray.exe",
            r"C:\Users\me\aap-runner-tray.txt",
            r"C:\Users\me\CON.exe",
            r"C:\Users\nul\aap-runner-tray.exe",
            r"C:\Users\me\com1.exe",
            r"C:\Users\me\x.exe ",
            "C:\\Users\\me\\a\"b.exe",
            "C:\\Users\\me\\a\nb.exe",
        ] {
            assert!(check_path(bad).is_err(), "{bad:?}");
        }
        assert!(check_path(&format!(r"C:\{}.exe", "a".repeat(1100))).is_err());
    }

    #[test]
    fn only_the_installed_tray_may_update_itself() {
        let dir = Path::new(INSTALL_DIR);
        let installed = installed_path(dir);
        assert_eq!(check_self(&installed, dir).unwrap(), installed);
        assert!(
            check_self(
                Path::new(r"c:\program files\AAP-RUNNER\aap-runner-tray.exe"),
                dir
            )
            .is_ok(),
            "NTFS compares names case-insensitively"
        );
        for wrong in [
            r"C:\Users\me\Downloads\aap-runner-tray.exe",
            r"C:\Program Files\aap-runner\staging\aap-runner-tray.exe",
            r"C:\Program Files\aap-runner\other.exe",
            r"D:\Program Files\aap-runner\aap-runner-tray.exe",
        ] {
            assert!(check_self(Path::new(wrong), dir).is_err(), "{wrong}");
        }
    }

    #[test]
    fn a_tray_pe_passes_the_image_check() {
        assert_eq!(check_image(&good_pe()).unwrap(), V050);
    }

    /// The rc's VERSIONINFO, as the real resource compiler lays it out, passes the same check.
    #[test]
    fn this_build_passes_its_own_image_check() {
        let me = fs::read(std::env::current_exe().unwrap()).unwrap();
        let v = |k: &str| k.parse::<u64>().unwrap();
        let want = (v(env!("CARGO_PKG_VERSION_MAJOR")) << 48)
            | (v(env!("CARGO_PKG_VERSION_MINOR")) << 32)
            | (v(env!("CARGO_PKG_VERSION_PATCH")) << 16);
        assert_eq!(
            check_image(&me).unwrap(),
            want,
            "FILEVERSION is the Cargo version"
        );
    }

    #[test]
    fn wrong_images_are_refused() {
        let blob = version_blob(PRODUCT, TRAY_NAME);
        assert!(check_image(b"not a pe at all").is_err());
        assert!(check_image(&[]).is_err());
        assert!(check_image(&pe(0x014c, &blob)).is_err(), "x86");
        assert!(check_image(&pe(0xaa64, &blob)).is_err(), "arm64");
        assert!(check_image(&pe(0x8664, &version_blob("other", TRAY_NAME))).is_err());
        assert!(check_image(&pe(0x8664, &version_blob(PRODUCT, "other.exe"))).is_err());
        let mut no_mz = good_pe();
        no_mz[0] = b'X';
        assert!(check_image(&no_mz).is_err());
        let mut pe32 = good_pe();
        put16(&mut pe32, 0x58, 0x10b);
        assert!(check_image(&pe32).is_err(), "PE32 optional header");
        let mut dll = good_pe();
        put16(&mut dll, 0x56, 0x2022);
        assert!(check_image(&dll).is_err(), "DLL");
        let mut no_rsrc = good_pe();
        put32(&mut no_rsrc, 0x58 + 112 + 16, 0);
        assert!(check_image(&no_rsrc).is_err(), "no resource directory");
        let good = good_pe();
        for cut in [0x30, 0x60, 0x150, 0x220, good.len() - 20] {
            assert!(check_image(&good[..cut]).is_err(), "truncated at {cut}");
        }
        let mut wild = good_pe();
        put32(&mut wild, 0x200 + 20, 0x7fff_fff0);
        assert!(check_image(&wild).is_err(), "directory offset out of range");
    }

    #[test]
    fn verification_uses_the_staged_copy_not_the_source() {
        let dir = temp();
        let source = dir.join("aap-runner-tray.exe");
        let good = good_pe();
        fs::write(&source, &good).unwrap();
        let staged = dir.join("staged.exe");
        copy_candidate(&source.display().to_string(), &staged, anywhere).unwrap();
        // The user (or anything running as the user) rewrites the source after the copy.
        let evil = pe(0x8664, &version_blob(PRODUCT, TRAY_NAME))
            .into_iter()
            .chain(*b"evil")
            .collect::<Vec<u8>>();
        fs::write(&source, &evil).unwrap();
        assert_eq!(
            verify_staged(&staged, &sha_of(&good), V050).unwrap(),
            sha_of(&good)
        );
        assert!(
            verify_staged(&staged, &sha_of(&evil), V050).is_err(),
            "the source's new hash does not match what was staged"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_bad_hash_or_a_non_pe_is_refused_after_staging() {
        let dir = temp();
        let staged = dir.join("staged.exe");
        fs::write(&staged, good_pe()).unwrap();
        let err = verify_staged(&staged, &"0".repeat(64), 0).unwrap_err();
        assert!(err.contains("sha256"), "{err}");
        assert!(
            err.contains(&"0".repeat(64)),
            "names the expected hash: {err}"
        );
        assert!(
            !err.contains(&sha_of(&good_pe())),
            "never the computed one (status.json is readable by every user): {err}"
        );
        let text = b"MZ but not really".to_vec();
        fs::write(&staged, &text).unwrap();
        assert!(verify_staged(&staged, &sha_of(&text), 0).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn copy_refuses_links_directories_and_existing_targets() {
        let dir = temp();
        let source = dir.join("a.exe");
        fs::write(&source, good_pe()).unwrap();
        let staged = dir.join("staged.exe");
        fs::write(&staged, b"already").unwrap();
        assert!(
            copy_candidate(&source.display().to_string(), &staged, anywhere).is_err(),
            "create-new only"
        );
        fs::remove_file(&staged).unwrap();
        let folder = dir.join("folder.exe");
        fs::create_dir(&folder).unwrap();
        assert!(copy_candidate(&folder.display().to_string(), &staged, anywhere).is_err());
        assert!(!staged.exists());
        let link = dir.join("link.exe");
        if std::os::windows::fs::symlink_file(&source, &link).is_ok() {
            assert!(copy_candidate(&link.display().to_string(), &staged, anywhere).is_err());
            assert!(!staged.exists());
        }
        let empty = dir.join("empty.exe");
        fs::write(&empty, b"").unwrap();
        assert!(copy_candidate(&empty.display().to_string(), &staged, anywhere).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn swap_moves_the_new_build_in_and_keeps_the_old_as_prev() {
        let dir = temp();
        let installed = dir.join(TRAY_NAME);
        let staged = dir.join("staging.exe");
        fs::write(&installed, b"old").unwrap();
        fs::write(dir.join("aap-runner-tray.exe.prev"), b"older").unwrap();
        fs::write(&staged, b"new").unwrap();
        swap_in(&staged, &installed, Duration::ZERO).unwrap();
        assert_eq!(fs::read(&installed).unwrap(), b"new");
        assert_eq!(
            fs::read(dir.join("aap-runner-tray.exe.prev")).unwrap(),
            b"old"
        );
        assert!(!staged.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_swap_restores_the_old_build() {
        let dir = temp();
        let installed = dir.join(TRAY_NAME);
        fs::write(&installed, b"old").unwrap();
        let missing = dir.join("gone.exe");
        assert!(swap_in(&missing, &installed, Duration::ZERO).is_err());
        assert_eq!(fs::read(&installed).unwrap(), b"old");
        assert!(!dir.join("aap-runner-tray.exe.prev").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_prev_that_cannot_be_removed_leaves_the_live_build_alone() {
        let dir = temp();
        let installed = dir.join(TRAY_NAME);
        let staged = dir.join("staging.exe");
        fs::write(&installed, b"old").unwrap();
        fs::write(&staged, b"new").unwrap();
        // A directory named .prev cannot be removed with remove_file.
        fs::create_dir(dir.join("aap-runner-tray.exe.prev")).unwrap();
        assert!(swap_in(&staged, &installed, Duration::ZERO).is_err());
        assert_eq!(fs::read(&installed).unwrap(), b"old");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_older_version_than_the_installed_one_is_refused() {
        let dir = temp();
        let staged = dir.join("staged.exe");
        let older = pe(0x8664, &version_blob_at(PRODUCT, TRAY_NAME, 4 << 32));
        fs::write(&staged, &older).unwrap();
        let err = verify_staged(&staged, &sha_of(&older), V050).unwrap_err();
        assert!(err.contains("older"), "{err}");
        assert!(
            verify_staged(&staged, &sha_of(&older), 4 << 32).is_ok(),
            "same version"
        );
        assert!(
            verify_staged(&staged, &sha_of(&older), 0).is_ok(),
            "installed has no version"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_installed_version_of_a_build_without_a_resource_is_zero() {
        assert_eq!(installed_version(b"MZ old build"), 0);
        assert_eq!(installed_version(&good_pe()), V050);
    }

    #[test]
    fn a_candidate_another_account_can_write_is_refused() {
        let dir = temp();
        let source = dir.join("aap-runner-tray.exe");
        fs::write(&source, good_pe()).unwrap();
        grant(&source, "*S-1-1-0:(W)");
        let staged = dir.join("staged.exe");
        let me = user();
        let err = copy_candidate(
            &source.display().to_string(),
            &staged,
            private_location(&me),
        )
        .unwrap_err();
        // The file's own ACL is checked before the folders.
        assert!(err.contains("writable only by you"), "{err}");
        assert!(!staged.exists());
        assert!(open_candidate(&source.display().to_string(), private_location(&me)).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_candidate_in_a_folder_another_account_can_modify_is_refused() {
        let dir = temp();
        let folder = dir.join("shared");
        fs::create_dir(&folder).unwrap();
        let source = folder.join("aap-runner-tray.exe");
        fs::write(&source, good_pe()).unwrap();
        // The file itself passes, so the refusal is the folder's: Authenticated Users may
        // modify the folder (not inherited by the file).
        make_private(&source);
        grant(&folder, "*S-1-5-11:(M)");
        let staged = dir.join("staged.exe");
        let me = user();
        let err = copy_candidate(
            &source.display().to_string(),
            &staged,
            private_location(&me),
        )
        .unwrap_err();
        assert!(err.contains("folder permits another account"), "{err}");
        assert!(!staged.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_hard_linked_candidate_is_refused() {
        let dir = temp();
        let source = dir.join("aap-runner-tray.exe");
        fs::write(&source, good_pe()).unwrap();
        fs::hard_link(&source, dir.join("other-name.exe")).unwrap();
        let staged = dir.join("staged.exe");
        let err = copy_candidate(&source.display().to_string(), &staged, anywhere).unwrap_err();
        assert!(err.contains("hard link"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_private_candidate_opens_for_the_early_check() {
        let dir = temp();
        let source = dir.join("aap-runner-tray.exe");
        fs::write(&source, good_pe()).unwrap();
        assert_eq!(
            open_candidate(&source.display().to_string(), anywhere)
                .unwrap()
                .1,
            good_pe().len() as u64
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_confirmation_names_path_size_and_hash() {
        let text = confirm_text(
            r"C:\Users\me\Downloads\aap-runner-tray.exe",
            1234,
            &"a".repeat(64),
        );
        assert!(
            text.contains(r"C:\Users\me\Downloads\aap-runner-tray.exe"),
            "{text}"
        );
        assert!(text.contains("1234 bytes"), "{text}");
        assert!(text.contains(&"a".repeat(64)), "{text}");
    }

    #[test]
    fn remove_prev_deletes_the_old_build_and_tolerates_none() {
        let dir = temp();
        let installed = dir.join(TRAY_NAME);
        fs::write(&installed, b"new").unwrap();
        assert!(!remove_prev(&installed), "nothing to remove");
        fs::write(prev_path(&installed), b"old").unwrap();
        assert!(remove_prev(&installed));
        assert!(!prev_path(&installed).exists());
        assert_eq!(fs::read(&installed).unwrap(), b"new");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_staging_folder_grants_only_system_and_administrators() {
        let dir = temp().join("staging");
        crate::win::create_private_dir(&dir).unwrap();
        // The test user owns it but has no ACE, so it cannot open it to read the ACL: add one
        // (icacls only needs the owner's implicit rights) and leave it out of the comparison.
        let me = user();
        grant(&dir, &format!("*{me}:(F)"));
        let acl = crate::win::acl_of_path(&dir, true).unwrap();
        let sids: Vec<&str> = acl
            .aces
            .iter()
            .map(|a| a.sid.as_str())
            .filter(|sid| *sid != me)
            .collect();
        assert_eq!(sids, ["S-1-5-18", "S-1-5-32-544"], "no Users read ACE");
        let _ = fs::remove_dir_all(dir.parent().unwrap());
    }

    #[test]
    fn the_staged_copy_gets_the_install_acl_before_it_moves() {
        let dir = temp();
        let file = dir.join("staged.exe");
        fs::write(&file, b"x").unwrap();
        crate::win::set_install_acl(&file).unwrap();
        let acl = crate::win::acl_of_path(&file, true).unwrap();
        let mut sids: Vec<&str> = acl.aces.iter().map(|a| a.sid.as_str()).collect();
        sids.sort();
        assert_eq!(sids, ["S-1-5-18", "S-1-5-32-544", "S-1-5-32-545"]);
        let users = acl.aces.iter().find(|a| a.sid == "S-1-5-32-545").unwrap();
        assert!(users.allow && !users.other);
        assert_eq!(users.rights & 0x0002, 0, "users cannot write");
        assert_ne!(users.rights & 0x0020, 0, "users can execute");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_tray_hashes_what_it_asks_for() {
        let dir = temp();
        let file = dir.join("aap-runner-tray.exe");
        fs::write(&file, b"abc").unwrap();
        assert_eq!(sha256_file(&file).unwrap(), sha_of(b"abc"));
        let _ = fs::remove_dir_all(&dir);
    }
}
