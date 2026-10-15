//! Identity page: org, GitHub App id, installation id, runner group, labels, and the path of the
//! downloaded private key. The checks are pure functions; [`Store`] keeps the typed text in
//! `%LOCALAPPDATA%\aap-runner\identity.json` and re-checks the key file every 5 s.
//!
//! Only the key's size and first line are read, into a buffer that is zeroed before it is dropped.
//! The key bytes never reach the store, the disk file, a log, or a request: only the path does.

use crate::github_setup::{self, Phase};
use crate::state;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const RECHECK: Duration = Duration::from_secs(5);
pub const GROUP_DEFAULT: &str = github_setup::GROUP_DEFAULT;
/// What `manager.conf.example` ships. The manager refuses a label line without its base label.
pub const LABELS_DEFAULT: &str = "self-hosted,linux,crrr";
pub const KEY_MAX: u64 = 16 * 1024;
const REPARSE: u32 = 0x400;
const PEM_HEADERS: [&str; 2] = [
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN PRIVATE KEY-----",
];

/// `[1-9][0-9]*` that fits a u64. No sign, no zero, no leading zero.
pub fn parse_id(text: &str, what: &str) -> Result<u64, String> {
    let t = text.trim();
    let shape = !t.is_empty() && !t.starts_with('0') && t.bytes().all(|b| b.is_ascii_digit());
    match t.parse::<u64>() {
        Ok(n) if shape && n > 0 => Ok(n),
        _ => Err(format!("{what} must be a positive integer")),
    }
}

/// GitHub slug: 1 to 39 of `[A-Za-z0-9-]`, no leading, trailing, or double hyphen.
pub fn slug_ok(text: &str) -> bool {
    let b = text.as_bytes();
    (1..=39).contains(&b.len())
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-')
        && b[0] != b'-'
        && b[b.len() - 1] != b'-'
        && !text.contains("--")
}

fn check_slug(text: &str, what: &str) -> Result<String, String> {
    let t = text.trim();
    if slug_ok(t) {
        Ok(t.to_string())
    } else {
        Err(format!(
            "{what} must be 1 to 39 letters, digits, or hyphens, with no leading, trailing, or double hyphen"
        ))
    }
}

pub fn check_org(text: &str) -> Result<String, String> {
    check_slug(text, "Org")
}

pub fn check_group(text: &str) -> Result<String, String> {
    check_slug(text, "Runner group")
}

/// Comma list. Items are trimmed, empty items dropped, duplicates dropped, each `[a-z0-9-]+`.
pub fn parse_labels(text: &str) -> Result<Vec<String>, String> {
    let mut out: Vec<String> = Vec::new();
    for item in text.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        if !item
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Err(format!(
                "Label '{item}' must be lowercase letters, digits, or hyphens"
            ));
        }
        if !out.iter().any(|seen| seen == item) {
            out.push(item.to_string());
        }
    }
    if out.is_empty() {
        return Err("Labels must list at least one label".into());
    }
    Ok(out)
}

/// First line of `path` (at most 64 bytes, CR stripped). The buffer is zeroed before it is dropped.
fn pem_header_ok(path: &Path) -> std::io::Result<bool> {
    let mut buf = [0u8; 64];
    let mut file = std::fs::File::open(path)?;
    let mut n = 0;
    while n < buf.len() {
        let got = file.read(&mut buf[n..])?;
        if got == 0 {
            break;
        }
        n += got;
    }
    let end = buf[..n].iter().position(|b| *b == b'\n').unwrap_or(n);
    let line = &buf[..end];
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    let ok = PEM_HEADERS.iter().any(|h| h.as_bytes() == line);
    buf.fill(0);
    std::hint::black_box(&buf);
    Ok(ok)
}

/// A regular file (not a reparse point) under `profile`, under 16 KiB, starting with a PEM
/// private-key header. `Ok` carries the size. Ancestors are left to the helper.
pub fn check_key_file(path: &Path, profile: &Path) -> Result<u64, String> {
    if path.as_os_str().is_empty() {
        return Err("Pick the downloaded .pem file".into());
    }
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err("Key file was not found".into());
        }
        Err(_) => return Err("Key file could not be read".into()),
    };
    if meta.file_attributes() & REPARSE != 0 {
        return Err("Key file is a link or junction; pick the file itself".into());
    }
    if !meta.is_file() {
        return Err("Key file is not a regular file".into());
    }
    let size = meta.len();
    if size == 0 {
        return Err("Key file is empty".into());
    }
    if size >= KEY_MAX {
        return Err("Key file is larger than 16 KiB".into());
    }
    let under = std::fs::canonicalize(path)
        .ok()
        .zip(std::fs::canonicalize(profile).ok())
        .is_some_and(|(real, home)| real.starts_with(home));
    if !under {
        return Err(format!("Key file is not under {}", profile.display()));
    }
    match pem_header_ok(path) {
        Ok(true) => Ok(size),
        Ok(false) => Err(
            "Key file does not start with -----BEGIN RSA PRIVATE KEY----- or -----BEGIN PRIVATE KEY-----"
                .into(),
        ),
        Err(_) => Err("Key file could not be read".into()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowId {
    Org,
    AppId,
    Installation,
    Group,
    Labels,
    Key,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub id: RowId,
    pub title: &'static str,
    pub phase: Phase,
    pub missing: String,
}

/// The text as typed. `org` comes from the GitHub setup page and is empty until it resolved.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Fields {
    pub org: String,
    pub app_id: String,
    pub installation_id: String,
    pub group: String,
    pub labels: String,
    pub key_path: String,
}

/// Every row met: what goes into the request.
#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct Valid {
    pub org: String,
    pub app_id: u64,
    pub installation_id: u64,
    pub group: String,
    pub labels: String,
    pub key_path: String,
}

fn row(id: RowId, title: &'static str, result: Result<(), String>) -> Row {
    match result {
        Ok(()) => Row {
            id,
            title,
            phase: Phase::Met,
            missing: String::new(),
        },
        Err(missing) => Row {
            id,
            title,
            phase: Phase::Unmet,
            missing,
        },
    }
}

/// `key` is the last key-file check; `None` means it has not run yet (checking).
/// Every row below Org is blocked until the GitHub setup page resolved an organization.
pub fn rows(f: &Fields, key: Option<&Result<u64, String>>) -> Vec<Row> {
    let org = if f.org.is_empty() {
        Err("Resolve the organization on the GitHub setup page first".to_string())
    } else {
        check_org(&f.org).map(|_| ())
    };
    let org = row(RowId::Org, "Organization", org);
    if org.phase != Phase::Met {
        let blocked = |id, title| Row {
            id,
            title,
            phase: Phase::Blocked,
            missing: String::new(),
        };
        return vec![
            org,
            blocked(RowId::AppId, "App id"),
            blocked(RowId::Installation, "Installation id"),
            blocked(RowId::Group, "Runner group"),
            blocked(RowId::Labels, "Labels"),
            blocked(RowId::Key, "Private key file"),
        ];
    }
    let key_row = match key {
        None => Row {
            id: RowId::Key,
            title: "Private key file",
            phase: Phase::Checking,
            missing: String::new(),
        },
        Some(result) => row(RowId::Key, "Private key file", result.clone().map(|_| ())),
    };
    vec![
        org,
        row(
            RowId::AppId,
            "App id",
            parse_id(&f.app_id, "App id").map(|_| ()),
        ),
        row(
            RowId::Installation,
            "Installation id",
            parse_id(&f.installation_id, "Installation id").map(|_| ()),
        ),
        row(
            RowId::Group,
            "Runner group",
            check_group(&f.group).map(|_| ()),
        ),
        row(RowId::Labels, "Labels", parse_labels(&f.labels).map(|_| ())),
        key_row,
    ]
}

pub fn all_met(rows: &[Row]) -> bool {
    rows.iter().all(|r| r.phase == Phase::Met)
}

/// `Some` only when every row is met, with the ids parsed and the labels normalised.
pub fn validate(f: &Fields, key: Option<&Result<u64, String>>) -> Option<Valid> {
    if !all_met(&rows(f, key)) {
        return None;
    }
    Some(Valid {
        org: check_org(&f.org).ok()?,
        app_id: parse_id(&f.app_id, "App id").ok()?,
        installation_id: parse_id(&f.installation_id, "Installation id").ok()?,
        group: check_group(&f.group).ok()?,
        labels: parse_labels(&f.labels).ok()?.join(","),
        key_path: f.key_path.trim().to_string(),
    })
}

/// The `inbox\jobs\<id>.json` body for the `identity` verb: the fields plus the key path.
pub fn request_json(id: &str, v: &Valid) -> Vec<u8> {
    let mut body = serde_json::json!({ "schema": 1, "id": id, "verb": "identity" });
    if let (Some(map), Ok(serde_json::Value::Object(fields))) =
        (body.as_object_mut(), serde_json::to_value(v))
    {
        map.extend(fields);
    }
    serde_json::to_vec(&body).unwrap_or_default()
}

#[derive(Clone, Serialize, Deserialize)]
struct Disk {
    schema: u32,
    #[serde(default)]
    app_id: String,
    #[serde(default)]
    installation_id: String,
    #[serde(default)]
    group: String,
    #[serde(default)]
    labels: String,
    #[serde(default)]
    key_path: String,
}

impl Default for Disk {
    fn default() -> Self {
        Self {
            schema: 1,
            app_id: String::new(),
            installation_id: String::new(),
            group: GROUP_DEFAULT.into(),
            labels: LABELS_DEFAULT.into(),
            key_path: String::new(),
        }
    }
}

pub fn path() -> PathBuf {
    github_setup::data_file("identity.json")
}

fn load_disk(path: &Path) -> Disk {
    let Some(text) = state::read_bounded(path) else {
        return Disk::default();
    };
    match serde_json::from_str::<Disk>(&text) {
        Ok(disk) if disk.schema == 1 => disk,
        _ => Disk::default(),
    }
}

fn save_disk(path: &Path, disk: &Disk) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_vec(disk) {
        let _ = state::write_atomic(path, &text);
    }
}

pub struct Store {
    path: PathBuf,
    disk: Disk,
    org: String,
    /// When the key file was last checked, for which path, and the result.
    key: Option<(Instant, String, Result<u64, String>)>,
}

impl Store {
    pub fn load(path: PathBuf) -> Self {
        Self {
            disk: load_disk(&path),
            path,
            org: String::new(),
            key: None,
        }
    }

    /// From the GitHub setup page's resolved account; empty when none is resolved.
    pub fn set_org(&mut self, org: String) {
        self.org = org;
    }

    pub fn fields(&self) -> Fields {
        Fields {
            org: self.org.clone(),
            app_id: self.disk.app_id.clone(),
            installation_id: self.disk.installation_id.clone(),
            group: self.disk.group.clone(),
            labels: self.disk.labels.clone(),
            key_path: self.disk.key_path.clone(),
        }
    }

    fn set(&mut self, id: RowId, value: String) {
        let slot = match id {
            RowId::AppId => &mut self.disk.app_id,
            RowId::Installation => &mut self.disk.installation_id,
            RowId::Group => &mut self.disk.group,
            RowId::Labels => &mut self.disk.labels,
            RowId::Key => &mut self.disk.key_path,
            RowId::Org => return,
        };
        if *slot == value {
            return;
        }
        *slot = value;
        save_disk(&self.path, &self.disk);
    }

    pub fn set_app_id(&mut self, v: String) {
        self.set(RowId::AppId, v);
    }
    pub fn set_installation_id(&mut self, v: String) {
        self.set(RowId::Installation, v);
    }
    pub fn set_group(&mut self, v: String) {
        self.set(RowId::Group, v);
    }
    pub fn set_labels(&mut self, v: String) {
        self.set(RowId::Labels, v);
    }
    pub fn set_key_path(&mut self, v: String) {
        self.set(RowId::Key, v);
    }

    /// Re-check the key file when the path changed or [`RECHECK`] has passed.
    pub fn tick(&mut self, profile: &Path) {
        let path = self.disk.key_path.trim().to_string();
        let due = match &self.key {
            Some((at, checked, _)) => *checked != path || at.elapsed() >= RECHECK,
            None => true,
        };
        if due {
            let result = check_key_file(Path::new(&path), profile);
            self.key = Some((Instant::now(), path, result));
        }
    }

    fn key_result(&self) -> Option<&Result<u64, String>> {
        self.key.as_ref().map(|(_, _, r)| r)
    }

    pub fn rows(&self) -> Vec<Row> {
        rows(&self.fields(), self.key_result())
    }

    pub fn valid(&self) -> Option<Valid> {
        validate(&self.fields(), self.key_result())
    }

    /// What the GitHub setup checklist can tick on its own once these are supplied.
    pub fn identity(&self) -> github_setup::Identity {
        github_setup::Identity {
            app_id: parse_id(&self.disk.app_id, "App id").ok(),
            installation_id: parse_id(&self.disk.installation_id, "Installation id").ok(),
            key_present: self.key_result().is_some_and(|r| r.is_ok()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PEM: &str = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAtest-body-not-a-real-key\n-----END RSA PRIVATE KEY-----\n";

    fn home(name: &str) -> PathBuf {
        let dir = state::temp_base(name).join("profile");
        std::fs::create_dir_all(dir.join("Downloads")).unwrap();
        dir
    }

    fn good(home: &Path) -> Fields {
        Fields {
            org: "acme".into(),
            app_id: "123".into(),
            installation_id: "456".into(),
            group: GROUP_DEFAULT.into(),
            labels: LABELS_DEFAULT.into(),
            key_path: home.join("Downloads").join("k.pem").display().to_string(),
        }
    }

    #[test]
    fn ids_are_positive_integers_without_sign_or_leading_zero() {
        assert_eq!(parse_id("1", "App id"), Ok(1));
        assert_eq!(parse_id(" 1234567 ", "App id"), Ok(1_234_567));
        assert_eq!(parse_id("18446744073709551615", "App id"), Ok(u64::MAX));
        for bad in [
            "",
            "0",
            "007",
            "+5",
            "-5",
            "1.5",
            "1e3",
            "12a",
            "18446744073709551616",
            " ",
        ] {
            assert_eq!(
                parse_id(bad, "App id"),
                Err("App id must be a positive integer".into()),
                "{bad:?}"
            );
        }
        assert_eq!(
            parse_id("x", "Installation id").unwrap_err(),
            "Installation id must be a positive integer"
        );
    }

    #[test]
    fn org_and_group_follow_github_slug_rules() {
        for ok in ["a", "acme", "Acme-Inc", "a1-b2", &"x".repeat(39)] {
            assert!(slug_ok(ok), "{ok}");
        }
        for bad in [
            "",
            "-acme",
            "acme-",
            "ac--me",
            "ac_me",
            "ac.me",
            "ac me",
            &"x".repeat(40),
            "acme/repo",
        ] {
            assert!(!slug_ok(bad), "{bad:?}");
        }
        assert_eq!(check_org(" acme "), Ok("acme".into()));
        assert!(check_org("-x").unwrap_err().starts_with("Org must be"));
        assert_eq!(check_group("aap-crrr"), Ok("aap-crrr".into()));
        assert!(
            check_group("a--b")
                .unwrap_err()
                .starts_with("Runner group must be")
        );
    }

    #[test]
    fn labels_are_trimmed_deduped_lowercase_items() {
        assert_eq!(
            parse_labels(" self-hosted, linux ,crrr,linux, "),
            Ok(vec!["self-hosted".into(), "linux".into(), "crrr".into()])
        );
        assert_eq!(
            parse_labels(LABELS_DEFAULT).unwrap().join(","),
            LABELS_DEFAULT
        );
        assert_eq!(
            parse_labels(""),
            Err("Labels must list at least one label".into())
        );
        assert_eq!(
            parse_labels(" , ,"),
            Err("Labels must list at least one label".into())
        );
        assert_eq!(
            parse_labels("Linux"),
            Err("Label 'Linux' must be lowercase letters, digits, or hyphens".into())
        );
        assert!(parse_labels("a_b").is_err());
        assert!(parse_labels("a.b").is_err());
        assert!(parse_labels("a b").is_err());
    }

    #[test]
    fn the_key_file_must_be_a_small_pem_under_the_profile() {
        let home = home("identity-key");
        let key = home.join("Downloads").join("k.pem");
        std::fs::write(&key, PEM).unwrap();
        assert_eq!(check_key_file(&key, &home), Ok(PEM.len() as u64));
        let pkcs8 = home.join("p8.pem");
        std::fs::write(&pkcs8, "-----BEGIN PRIVATE KEY-----\r\nabc\r\n").unwrap();
        assert!(check_key_file(&pkcs8, &home).is_ok(), "CRLF and PKCS#8");
        assert_eq!(
            check_key_file(Path::new(""), &home),
            Err("Pick the downloaded .pem file".into())
        );
        assert_eq!(
            check_key_file(&home.join("missing.pem"), &home),
            Err("Key file was not found".into())
        );
        assert_eq!(
            check_key_file(&home.join("Downloads"), &home),
            Err("Key file is not a regular file".into())
        );
        let outside = home.parent().unwrap().join("outside.pem");
        std::fs::write(&outside, PEM).unwrap();
        assert_eq!(
            check_key_file(&outside, &home),
            Err(format!("Key file is not under {}", home.display()))
        );
        let empty = home.join("empty.pem");
        std::fs::write(&empty, "").unwrap();
        assert_eq!(
            check_key_file(&empty, &home),
            Err("Key file is empty".into())
        );
        let big = home.join("big.pem");
        let mut body = PEM.to_string();
        body.push_str(&"x".repeat(KEY_MAX as usize));
        std::fs::write(&big, body).unwrap();
        assert_eq!(
            check_key_file(&big, &home),
            Err("Key file is larger than 16 KiB".into())
        );
        let exact = home.join("exact.pem");
        std::fs::write(&exact, "x".repeat(KEY_MAX as usize)).unwrap();
        assert_eq!(
            check_key_file(&exact, &home),
            Err("Key file is larger than 16 KiB".into()),
            "16 KiB exactly is too large"
        );
        let cert = home.join("cert.pem");
        std::fs::write(&cert, "-----BEGIN CERTIFICATE-----\nabc\n").unwrap();
        assert!(
            check_key_file(&cert, &home)
                .unwrap_err()
                .starts_with("Key file does not start with")
        );
        let indented = home.join("indented.pem");
        std::fs::write(&indented, " -----BEGIN PRIVATE KEY-----\n").unwrap();
        assert!(check_key_file(&indented, &home).is_err());
        let _ = std::fs::remove_dir_all(home.parent().unwrap());
    }

    #[test]
    fn a_junction_is_refused_without_being_followed() {
        let home = home("identity-junction");
        let target = home.parent().unwrap().join("target");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("k.pem"), PEM).unwrap();
        let link = home.join("link");
        let status = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
            .args(["/d", "/c", "mklink", "/J"])
            .arg(&link)
            .arg(&target)
            .status()
            .unwrap();
        assert!(status.success(), "mklink /J");
        assert_eq!(
            check_key_file(&link, &home),
            Err("Key file is a link or junction; pick the file itself".into())
        );
        // The file behind the junction resolves outside the profile.
        assert_eq!(
            check_key_file(&link.join("k.pem"), &home),
            Err(format!("Key file is not under {}", home.display()))
        );
        let _ = std::process::Command::new(r"C:\Windows\System32\cmd.exe")
            .args(["/d", "/c", "rmdir"])
            .arg(&link)
            .status();
        let _ = std::fs::remove_dir_all(home.parent().unwrap());
    }

    #[test]
    fn rows_name_what_is_missing_and_apply_needs_every_row() {
        let home = home("identity-rows");
        let f = good(&home);
        let blocked = rows(&Fields::default(), None);
        assert_eq!(blocked[0].phase, Phase::Unmet);
        assert_eq!(
            blocked[0].missing,
            "Resolve the organization on the GitHub setup page first"
        );
        assert!(blocked[1..].iter().all(|r| r.phase == Phase::Blocked));
        assert!(validate(&Fields::default(), None).is_none());
        let checking = rows(&f, None);
        assert_eq!(checking[5].phase, Phase::Checking);
        assert!(!all_met(&checking));
        assert!(validate(&f, None).is_none());
        let unmet = rows(
            &Fields {
                app_id: "0".into(),
                installation_id: "-1".into(),
                group: "a--b".into(),
                labels: "".into(),
                ..f.clone()
            },
            Some(&Err("Key file was not found".into())),
        );
        assert_eq!(unmet[1].missing, "App id must be a positive integer");
        assert_eq!(
            unmet[2].missing,
            "Installation id must be a positive integer"
        );
        assert!(unmet[3].missing.starts_with("Runner group must be"));
        assert_eq!(unmet[4].missing, "Labels must list at least one label");
        assert_eq!(unmet[5].missing, "Key file was not found");
        assert!(unmet[1..].iter().all(|r| r.phase == Phase::Unmet));
        let ok = Ok(1234u64);
        let met = rows(&f, Some(&ok));
        assert!(all_met(&met), "{met:?}");
        let v = validate(
            &Fields {
                app_id: " 123 ".into(),
                labels: "linux, self-hosted,linux".into(),
                ..f.clone()
            },
            Some(&ok),
        )
        .unwrap();
        assert_eq!(v.app_id, 123);
        assert_eq!(v.labels, "linux,self-hosted");
        assert_eq!(v.key_path, f.key_path);
        let _ = std::fs::remove_dir_all(home.parent().unwrap());
    }

    #[test]
    fn the_request_carries_fields_and_path_but_never_key_bytes() {
        let home = home("identity-request");
        let key = home.join("Downloads").join("k.pem");
        std::fs::write(&key, PEM).unwrap();
        let v = validate(&good(&home), Some(&Ok(PEM.len() as u64))).unwrap();
        let body = request_json("0123456789abcdef", &v);
        let text = String::from_utf8(body).unwrap();
        let json: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(json["schema"], 1);
        assert_eq!(json["id"], "0123456789abcdef");
        assert_eq!(json["verb"], "identity");
        assert_eq!(json["org"], "acme");
        assert_eq!(json["app_id"], 123);
        assert_eq!(json["installation_id"], 456);
        assert_eq!(json["group"], "aap-crrr");
        assert_eq!(json["labels"], LABELS_DEFAULT);
        assert_eq!(json["key_path"], v.key_path);
        assert_eq!(json.as_object().unwrap().len(), 9);
        assert!(!text.contains("MIIEowIBAAKCAQEA"), "{text}");
        assert!(!text.contains("PRIVATE KEY"), "{text}");
        let _ = std::fs::remove_dir_all(home.parent().unwrap());
    }

    #[test]
    fn the_store_round_trips_and_rechecks_the_key_on_a_path_change() {
        let home = home("identity-store");
        let path = home.parent().unwrap().join("identity.json");
        let key = home.join("Downloads").join("k.pem");
        std::fs::write(&key, PEM).unwrap();
        let mut store = Store::load(path.clone());
        assert_eq!(store.fields().group, GROUP_DEFAULT);
        assert_eq!(store.fields().labels, LABELS_DEFAULT);
        assert_eq!(store.rows()[0].phase, Phase::Unmet, "no org yet");
        store.set_org("acme".into());
        store.set_app_id("123".into());
        store.set_installation_id("456".into());
        store.set_key_path(key.display().to_string());
        assert_eq!(store.rows()[5].phase, Phase::Checking);
        store.tick(&home);
        assert!(all_met(&store.rows()));
        assert!(store.valid().is_some());
        let id = store.identity();
        assert_eq!(id.app_id, Some(123));
        assert_eq!(id.installation_id, Some(456));
        assert!(id.key_present);
        store.set_key_path(home.join("nope.pem").display().to_string());
        store.tick(&home);
        assert_eq!(store.rows()[5].missing, "Key file was not found");
        assert!(!store.identity().key_present);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"app_id\":\"123\""), "{text}");
        assert!(!text.contains("PRIVATE KEY"));
        let again = Store::load(path.clone());
        assert_eq!(again.fields().installation_id, "456");
        assert!(again.fields().key_path.ends_with("nope.pem"));
        std::fs::write(&path, r#"{"schema":9,"app_id":"1"}"#).unwrap();
        assert!(Store::load(path).fields().app_id.is_empty());
        let _ = std::fs::remove_dir_all(home.parent().unwrap());
    }

    #[test]
    fn the_identity_file_sits_beside_github_setup() {
        let p = path();
        assert!(p.ends_with("identity.json"));
        assert_eq!(p.parent(), github_setup::path().parent());
    }
}
