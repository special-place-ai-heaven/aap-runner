//! GitHub setup checklist. The public API answers who the owner is. No token is
//! read, sent, or stored. A row the app cannot see yet stays a manual tick until
//! a later input (the identity page) makes it checkable.
//!
//! ponytail: fork policy has no API check, so an organization ticks that row by hand.
//! A user account stops the checklist; the manager only registers organization runners.
//! The dashboard passes the identity page's ids and the last Verify's app-token row into the store.

use crate::state;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const ADVANCE_AFTER: Duration = Duration::from_secs(2);
pub const GROUP_DEFAULT: &str = "aap-crrr";
const APP_PERMS: &str = "Required permissions: Organization > Self-hosted runners: Read and write; Repository > Actions: Read. Webhook off. Choose Only on this account.";
const APP_NEW: &str =
    "?public=false&webhook_active=false&organization_self_hosted_runners=write&actions=read";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Org,
    User,
}

fn repo_is_verified() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub login: String,
    pub kind: Kind,
    pub repo: Option<String>,
    /// False when owner/repo was given and the public API returned 404.
    #[serde(default = "repo_is_verified")]
    pub repo_verified: bool,
    pub public_repos: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Manual {
    pub create_app: bool,
    pub install: bool,
    pub private_key: bool,
    pub runner_group: bool,
    pub fork_policy: bool,
}

/// Filled by the identity page (M3). Empty means those rows stay manual.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Identity {
    pub app_id: Option<u64>,
    pub installation_id: Option<u64>,
    pub key_present: bool,
}

/// Helper App-token check. None means that check has not run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Verify {
    pub app_authenticates: Option<bool>,
    pub installation_matches: Option<bool>,
    pub runner_group_exists: Option<bool>,
}

#[derive(Clone, Debug)]
pub struct Facts {
    pub account: Option<Account>,
    pub error: Option<String>,
    pub checking: bool,
    pub group: String,
    pub manual: Manual,
    pub identity: Identity,
    pub verify: Verify,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Checking,
    Met,
    Unmet,
    Blocked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowId {
    Account,
    CreateApp,
    Install,
    Key,
    Group,
    Fork,
    Workflow,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub id: RowId,
    pub phase: Phase,
    pub title: &'static str,
    pub manual: bool,
    pub missing: String,
    pub action: String,
    pub link: Option<String>,
    pub copy: Option<String>,
    pub show_group: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Links {
    pub create_app: String,
    pub apps: String,
    pub install_pattern: String,
    pub runner_groups: Option<String>,
    pub actions: String,
}

pub fn ready_to_advance(all_met: bool, armed: bool, elapsed: Duration) -> bool {
    all_met && armed && elapsed >= ADVANCE_AFTER
}

pub fn group_ok(name: &str) -> bool {
    let n = name.trim();
    !n.is_empty()
        && n.len() <= 100
        && n.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn slug(name: &str) -> bool {
    let b = name.as_bytes();
    (1..40).contains(&b.len())
        && b[0].is_ascii_alphanumeric()
        && b[b.len() - 1].is_ascii_alphanumeric()
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-')
}

fn repo_name(name: &str) -> bool {
    (1..=100).contains(&name.len())
        && name != "."
        && name != ".."
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Parsed {
    owner: String,
    repo: Option<String>,
}

fn parse_target(raw: &str) -> Result<Parsed, &'static str> {
    let s = raw.trim();
    let s = s
        .strip_prefix("https://github.com/")
        .or_else(|| s.strip_prefix("http://github.com/"))
        .unwrap_or(s);
    let s = s.trim_matches('/');
    if s.is_empty() {
        return Err("Enter an org slug, or owner/repo.");
    }
    let mut parts = s.split('/');
    let owner = parts.next().unwrap_or("");
    let repo = parts.next();
    if parts.next().is_some() {
        return Err("Use an org slug, or owner/repo.");
    }
    if !slug(owner) {
        return Err("That owner is not a GitHub slug.");
    }
    let repo = match repo {
        None => None,
        Some("") => return Err("Use an org slug, or owner/repo."),
        Some(repo) if repo_name(repo) => Some(repo.to_string()),
        Some(_) => return Err("That repository name is not allowed."),
    };
    Ok(Parsed {
        owner: owner.to_string(),
        repo,
    })
}

pub fn links(kind: Kind, login: &str) -> Option<Links> {
    if kind != Kind::Org || !slug(login) {
        return None;
    }
    Some(Links {
        create_app: format!("https://github.com/organizations/{login}/settings/apps/new{APP_NEW}"),
        apps: format!("https://github.com/organizations/{login}/settings/apps"),
        install_pattern: format!(
            "https://github.com/organizations/{login}/settings/apps/<app>/installations"
        ),
        runner_groups: Some(format!(
            "https://github.com/organizations/{login}/settings/actions/runner-groups"
        )),
        actions: format!("https://github.com/organizations/{login}/settings/actions"),
    })
}

pub fn workflow(group: &str) -> String {
    format!(
        "runs-on: {{group: {}, labels: [self-hosted, linux]}}",
        group.trim()
    )
}

fn blank(id: RowId, title: &'static str, phase: Phase) -> Row {
    Row {
        id,
        phase,
        title,
        manual: false,
        missing: String::new(),
        action: String::new(),
        link: None,
        copy: None,
        show_group: false,
    }
}

fn blocked(id: RowId, title: &'static str) -> Row {
    blank(id, title, Phase::Blocked)
}

fn row(
    id: RowId,
    title: &'static str,
    phase: Phase,
    manual: bool,
    missing: impl Into<String>,
    action: impl Into<String>,
    link: Option<String>,
) -> Row {
    Row {
        id,
        phase,
        title,
        manual,
        missing: missing.into(),
        action: action.into(),
        link,
        copy: None,
        show_group: false,
    }
}

struct Check {
    id: RowId,
    title: &'static str,
    /// `Some(true)` passed, `Some(false)` failed, `None` not run.
    ok: Option<bool>,
    known: bool,
    ticked: bool,
    fail: &'static str,
    missing: &'static str,
    action: String,
    link: Option<String>,
}

fn decided(c: Check) -> Row {
    if c.ok == Some(false) {
        return row(c.id, c.title, Phase::Unmet, false, c.fail, c.action, c.link);
    }
    if c.known || c.ok == Some(true) {
        return row(c.id, c.title, Phase::Met, false, "", c.action, c.link);
    }
    if c.ticked {
        return row(c.id, c.title, Phase::Met, true, "", c.action, c.link);
    }
    row(
        c.id,
        c.title,
        Phase::Unmet,
        true,
        c.missing,
        c.action,
        c.link,
    )
}

/// Every checklist row, in order. A row stays blocked until the one above it is met.
pub fn rows(facts: &Facts) -> Vec<Row> {
    let account = account_row(facts);
    let account_met = account.phase == Phase::Met;
    let kind = facts.account.as_ref().map(|a| a.kind);
    let login = facts.account.as_ref().map(|a| a.login.as_str());
    let linked = kind.zip(login).and_then(|(k, n)| links(k, n));
    let create_link = linked.as_ref().map(|l| l.create_app.clone());
    let apps = linked.as_ref().map(|l| l.apps.clone());
    let create = if account_met {
        decided(Check {
            id: RowId::CreateApp,
            title: "Create a GitHub App",
            ok: facts.verify.app_authenticates,
            known: facts.identity.app_id.is_some(),
            ticked: facts.manual.create_app,
            fail: "The app did not authenticate.",
            missing: "The GitHub App has not been created.",
            action: APP_PERMS.into(),
            link: create_link,
        })
    } else {
        blocked(RowId::CreateApp, "Create a GitHub App")
    };
    let install_action = linked.as_ref().map_or(String::new(), |l| format!("Open the app from the list, then install it at {}. The App ID is on the app page. The Installation ID is the number in the installation URL. The next page asks for both.", l.install_pattern));
    let install = if create.phase == Phase::Met {
        decided(Check {
            id: RowId::Install,
            title: "Install the app",
            ok: facts.verify.installation_matches,
            known: facts.identity.installation_id.is_some(),
            ticked: facts.manual.install,
            fail: "The installation id does not match.",
            missing: "The app is not installed on this account.",
            action: install_action,
            link: apps.clone(),
        })
    } else {
        blocked(RowId::Install, "Install the app")
    };
    let key_action = "On the app page, generate a private key and download the .pem. The identity page asks for that file. Do not paste the key here.";
    let key = if install.phase == Phase::Met {
        decided(Check {
            id: RowId::Key,
            title: "Private key",
            ok: None,
            known: facts.identity.key_present,
            ticked: facts.manual.private_key,
            fail: "",
            missing: "The private key has not been downloaded.",
            action: key_action.into(),
            link: apps,
        })
    } else {
        blocked(RowId::Key, "Private key")
    };
    let group = group_row(facts, key.phase == Phase::Met, linked.as_ref());
    let fork = fork_row(facts, group.phase == Phase::Met, linked.as_ref());
    let flow = workflow_row(facts, fork.phase == Phase::Met);
    vec![account, create, install, key, group, fork, flow]
}

fn account_row(facts: &Facts) -> Row {
    if facts.checking {
        return row(
            RowId::Account,
            "Account",
            Phase::Checking,
            false,
            "",
            "Looking up the public GitHub API.",
            None,
        );
    }
    if let Some(account) = &facts.account {
        if account.kind == Kind::User {
            return row(
                RowId::Account,
                "Account",
                Phase::Unmet,
                false,
                format!(
                    "Only organizations are supported; {} is a user account.",
                    account.login
                ),
                "",
                None,
            );
        }
        let where_ = match &account.repo {
            Some(repo) => format!("{}/{}", account.login, repo),
            None => account.login.clone(),
        };
        let unverified = if account.repo_verified {
            ""
        } else {
            " The repository could not be verified; it may be private."
        };
        return row(
            RowId::Account,
            "Account",
            Phase::Met,
            false,
            "",
            format!("{where_} is an organization.{unverified}"),
            None,
        );
    }
    row(
        RowId::Account,
        "Account",
        Phase::Unmet,
        false,
        facts
            .error
            .clone()
            .unwrap_or_else(|| "Enter an org slug, or owner/repo.".into()),
        "Enter an org slug, or owner/repo. Nothing private is requested.",
        None,
    )
}

fn group_row(facts: &Facts, prev: bool, links: Option<&Links>) -> Row {
    if !prev {
        return blocked(RowId::Group, "Runner group");
    }
    let link = links.and_then(|l| l.runner_groups.clone());
    let action = format!(
        "Create the group (default name {GROUP_DEFAULT}). Tick Allow public repositories, then add the repositories."
    );
    if facts.verify.runner_group_exists == Some(false) {
        return row(
            RowId::Group,
            "Runner group",
            Phase::Unmet,
            false,
            "The runner group was not found.",
            action,
            link,
        );
    }
    let mut r = if facts.verify.runner_group_exists == Some(true) {
        row(
            RowId::Group,
            "Runner group",
            Phase::Met,
            false,
            "",
            action,
            link,
        )
    } else if !group_ok(&facts.group) {
        row(
            RowId::Group,
            "Runner group",
            Phase::Unmet,
            false,
            "Enter a runner group name: letters, digits, hyphen, or underscore.",
            action,
            link,
        )
    } else if facts.manual.runner_group {
        row(
            RowId::Group,
            "Runner group",
            Phase::Met,
            true,
            "",
            action,
            link,
        )
    } else {
        row(
            RowId::Group,
            "Runner group",
            Phase::Unmet,
            true,
            "The runner group has not been created.",
            action,
            link,
        )
    };
    r.show_group = true;
    r
}

fn fork_row(facts: &Facts, prev: bool, links: Option<&Links>) -> Row {
    if !prev {
        return blocked(RowId::Fork, "Fork policy");
    }
    let action = "Require approval for all outside collaborators.";
    let link = links.map(|l| l.actions.clone());
    if facts.manual.fork_policy {
        row(
            RowId::Fork,
            "Fork policy",
            Phase::Met,
            true,
            "",
            action,
            link,
        )
    } else {
        row(
            RowId::Fork,
            "Fork policy",
            Phase::Unmet,
            true,
            "Outside collaborators can still run workflows without approval.",
            action,
            link,
        )
    }
}

fn workflow_row(facts: &Facts, prev: bool) -> Row {
    if !prev {
        return blocked(RowId::Workflow, "Workflow");
    }
    let mut r = row(
        RowId::Workflow,
        "Workflow",
        Phase::Met,
        false,
        "",
        "Use this runs-on value.",
        None,
    );
    r.copy = Some(workflow(&facts.group));
    r
}

pub fn first_open(list: &[Row]) -> Option<RowId> {
    list.iter()
        .find(|r| r.phase == Phase::Unmet || r.phase == Phase::Checking)
        .map(|r| r.id)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FailKind {
    NotFound,
    RateLimit,
    Network,
    /// Response body could not be used. Final: not retried like a dropped connection.
    Body,
    Other,
}

fn remembers(kind: FailKind) -> bool {
    matches!(
        kind,
        FailKind::NotFound | FailKind::RateLimit | FailKind::Body
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LookupError {
    kind: FailKind,
    message: String,
    until: Option<SystemTime>,
}

impl LookupError {
    fn new(kind: FailKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            until: None,
        }
    }

    fn rate_limit(until: SystemTime) -> Self {
        Self {
            kind: FailKind::RateLimit,
            message: try_again_at(until, crate::win::local_offset_secs()),
            until: Some(until),
        }
    }
}

/// `repo` is `(status, body, requested name)` when the input was owner/repo.
pub fn account_from(
    user_status: u16,
    user_body: &str,
    repo: Option<(u16, &str, &str)>,
) -> Result<Account, LookupError> {
    let user = interpret_user(user_status, user_body)?;
    let repo = match repo {
        None => None,
        Some((status, body, name)) => Some(interpret_repo(status, body, name)?),
    };
    if !slug(&user.login) {
        return Err(LookupError::new(
            FailKind::Other,
            "GitHub returned an unexpected login.",
        ));
    }
    let repo_verified = repo.as_ref().is_none_or(|hit| hit.verified);
    Ok(Account {
        login: user.login,
        kind: user.kind,
        repo: repo.map(|hit| hit.name),
        repo_verified,
        public_repos: user.public_repos,
    })
}

struct UserHit {
    login: String,
    kind: Kind,
    public_repos: u64,
}

fn interpret_user(status: u16, body: &str) -> Result<UserHit, LookupError> {
    if status == 404 {
        return Err(LookupError::new(
            FailKind::NotFound,
            "That account was not found.",
        ));
    }
    if status != 200 {
        return Err(status_error(status, body));
    }
    #[derive(Deserialize)]
    struct Body {
        login: String,
        #[serde(rename = "type")]
        kind: String,
        public_repos: Option<u64>,
    }
    let body: Body = serde_json::from_str(body)
        .map_err(|_| LookupError::new(FailKind::Other, "GitHub returned an unexpected account."))?;
    let kind = match body.kind.as_str() {
        "Organization" => Kind::Org,
        "User" => Kind::User,
        _ => {
            return Err(LookupError::new(
                FailKind::Other,
                "GitHub returned an unexpected account type.",
            ));
        }
    };
    Ok(UserHit {
        login: body.login,
        kind,
        public_repos: body.public_repos.unwrap_or(0),
    })
}

struct RepoHit {
    name: String,
    verified: bool,
}

fn interpret_repo(status: u16, body: &str, requested: &str) -> Result<RepoHit, LookupError> {
    if status == 404 {
        if !repo_name(requested) {
            return Err(LookupError::new(
                FailKind::Other,
                "That repository name is not allowed.",
            ));
        }
        return Ok(RepoHit {
            name: requested.to_string(),
            verified: false,
        });
    }
    if status != 200 {
        return Err(status_error(status, body));
    }
    #[derive(Deserialize)]
    struct Body {
        name: String,
    }
    let body: Body = serde_json::from_str(body).map_err(|_| {
        LookupError::new(FailKind::Other, "GitHub returned an unexpected repository.")
    })?;
    if !repo_name(&body.name) {
        return Err(LookupError::new(
            FailKind::Other,
            "GitHub returned an unexpected repository name.",
        ));
    }
    Ok(RepoHit {
        name: body.name,
        verified: true,
    })
}

fn status_error(status: u16, body: &str) -> LookupError {
    if status == 429 || body.to_ascii_lowercase().contains("rate limit") {
        LookupError::new(FailKind::RateLimit, "GitHub rate limit. Try again later.")
    } else {
        LookupError::new(FailKind::Other, format!("GitHub returned {status}."))
    }
}

/// `offset` is local time minus UTC in seconds, as the dashboard clock uses.
fn try_again_at(at: SystemTime, offset: i64) -> String {
    let secs = at
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // ponytail: local clock only, no date. A reset is capped at one hour out, so the date is never ambiguous.
    format!("try again at {}", crate::dashboard::clock(secs, offset))
}

/// First network retry waits 5 s, then 10, 20, and 40.
fn backoff(tries: u32) -> Duration {
    let shift = tries.saturating_sub(1).min(3);
    Duration::from_secs(5u64 << shift)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Disk {
    schema: u32,
    input: String,
    group: String,
    #[serde(default)]
    create_app: bool,
    #[serde(default)]
    install: bool,
    #[serde(default)]
    private_key: bool,
    #[serde(default)]
    runner_group: bool,
    #[serde(default)]
    fork_policy: bool,
    #[serde(default)]
    account: Option<Account>,
}

impl Default for Disk {
    fn default() -> Self {
        Self {
            schema: 1,
            input: String::new(),
            group: GROUP_DEFAULT.into(),
            create_app: false,
            install: false,
            private_key: false,
            runner_group: false,
            fork_policy: false,
            account: None,
        }
    }
}

impl Disk {
    fn manual(&self) -> Manual {
        Manual {
            create_app: self.create_app,
            install: self.install,
            private_key: self.private_key,
            runner_group: self.runner_group,
            fork_policy: self.fork_policy,
        }
    }
}

pub fn path() -> PathBuf {
    data_file("github-setup.json")
}

/// `%LOCALAPPDATA%\aap-runner\<name>`, or the temp directory when that variable is missing or empty.
pub(crate) fn data_file(name: &str) -> PathBuf {
    data_path(std::env::var_os("LOCALAPPDATA"), std::env::temp_dir(), name)
}

fn data_path(local: Option<std::ffi::OsString>, temp: PathBuf, name: &str) -> PathBuf {
    let root = match local {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => temp,
    };
    root.join("aap-runner").join(name)
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

struct Slot {
    ticket: u64,
    done: Option<(u64, Result<Account, LookupError>)>,
}

pub struct Store {
    path: PathBuf,
    disk: Disk,
    note: Option<String>,
    checking: bool,
    fail: Option<FailKind>,
    failed_input: Option<String>,
    net_tries: u32,
    next_retry: Option<Instant>,
    slot: Arc<Mutex<Slot>>,
    ticket: u64,
    /// Latest submit while a lookup is already running.
    pending: Option<String>,
    /// Text the in-flight lookup was started with. Empty when a result is injected.
    queried: String,
    /// 404, rate limit, and unusable body, keyed by the trimmed input.
    remembered: HashMap<String, (FailKind, String, Option<SystemTime>)>,
    /// From the identity page and the last Verify job; not persisted.
    identity: Identity,
    verify: Verify,
}

#[cfg(test)]
thread_local! {
    static HOLD_SPAWN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static SPAWNS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
fn hold_spawns(on: bool) {
    HOLD_SPAWN.with(|flag| flag.set(on));
    if on {
        SPAWNS.with(|n| n.set(0));
    }
}

#[cfg(test)]
fn spawns() -> u32 {
    SPAWNS.with(|n| n.get())
}

impl Store {
    pub fn load(path: PathBuf) -> Self {
        Self {
            disk: load_disk(&path),
            path,
            note: None,
            checking: false,
            fail: None,
            failed_input: None,
            net_tries: 0,
            next_retry: None,
            slot: Arc::new(Mutex::new(Slot {
                ticket: 0,
                done: None,
            })),
            ticket: 0,
            pending: None,
            queried: String::new(),
            remembered: HashMap::new(),
            identity: Identity::default(),
            verify: Verify::default(),
        }
    }

    pub fn set_identity(&mut self, identity: Identity) {
        self.identity = identity;
    }

    pub fn set_verify(&mut self, verify: Verify) {
        self.verify = verify;
    }

    /// The resolved organization's login, for the identity page; `None` until one is resolved.
    pub fn org(&self) -> Option<String> {
        self.facts()
            .account
            .filter(|a| a.kind == Kind::Org)
            .map(|a| a.login)
    }

    pub fn input(&self) -> &str {
        &self.disk.input
    }
    pub fn group(&self) -> &str {
        &self.disk.group
    }

    pub fn set_input(&mut self, input: String) {
        if input == self.disk.input {
            return;
        }
        self.disk.input = input;
        save_disk(&self.path, &self.disk);
    }

    /// Look up when the field is submitted or loses focus. Typing only stores the text.
    /// A submit during a lookup is kept and run when that lookup finishes.
    pub fn commit(&mut self) {
        if self.checking {
            self.pending = Some(self.disk.input.clone());
            // The in-flight response is stale. pump drops it because the ticket no longer matches.
            self.ticket = self.ticket.wrapping_add(1);
            return;
        }
        let input = self.disk.input.clone();
        self.lookup_input(&input);
    }

    fn lookup_input(&mut self, input: &str) {
        self.net_tries = 0;
        self.next_retry = None;
        let Ok(parsed) = parse_target(input) else {
            return;
        };
        if self
            .disk
            .account
            .as_ref()
            .is_some_and(|account| same_target(&parsed, account))
        {
            self.note = None;
            self.fail = None;
            self.failed_input = None;
            return;
        }
        let key = input.trim();
        if let Some((kind, message, until)) = self.remembered.get(key).cloned() {
            let expired =
                kind == FailKind::RateLimit && until.is_some_and(|at| SystemTime::now() >= at);
            if expired {
                self.remembered.remove(key);
            } else {
                self.note = Some(message);
                self.fail = Some(kind);
                self.failed_input = None;
                return;
            }
        }
        self.note = None;
        self.fail = None;
        self.failed_input = None;
        self.queried = input.to_string();
        self.checking = true;
        self.spawn(parsed);
    }

    pub fn set_group(&mut self, group: String) {
        if group == self.disk.group {
            return;
        }
        self.disk.group = group;
        save_disk(&self.path, &self.disk);
    }

    pub fn toggle(&mut self, id: RowId, on: bool) {
        let flag = match id {
            RowId::CreateApp => &mut self.disk.create_app,
            RowId::Install => &mut self.disk.install,
            RowId::Key => &mut self.disk.private_key,
            RowId::Group => &mut self.disk.runner_group,
            RowId::Fork => &mut self.disk.fork_policy,
            RowId::Account | RowId::Workflow => return,
        };
        if *flag == on {
            return;
        }
        *flag = on;
        save_disk(&self.path, &self.disk);
    }

    /// Retry a network error for the same text, after [`backoff`]. A 404, a rate limit, or an unusable body stays put.
    pub fn retry(&mut self) {
        if self.checking || self.fail != Some(FailKind::Network) {
            return;
        }
        if self.failed_input.as_deref() != Some(self.disk.input.as_str()) {
            return;
        }
        if self.next_retry.is_some_and(|at| Instant::now() < at) {
            return;
        }
        let Ok(parsed) = parse_target(&self.disk.input) else {
            return;
        };
        if self
            .disk
            .account
            .as_ref()
            .is_some_and(|account| same_target(&parsed, account))
        {
            return;
        }
        self.queried = self.disk.input.clone();
        self.checking = true;
        self.spawn(parsed);
    }

    pub fn pump(&mut self) {
        let done = {
            self.slot
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .done
                .take()
        };
        let Some((ticket, result)) = done else {
            return;
        };
        if ticket != self.ticket {
            self.finish_flight(None);
            return;
        }
        self.take_result(result);
    }

    pub fn rows(&self) -> Vec<Row> {
        rows(&self.facts())
    }

    fn facts(&self) -> Facts {
        let key = self.disk.input.trim().to_string();
        let matched = parse_target(&self.disk.input).ok().is_some_and(|parsed| {
            self.disk
                .account
                .as_ref()
                .is_some_and(|account| same_target(&parsed, account))
        });
        let cached = self
            .remembered
            .get(&key)
            .map(|(_, message, _)| message.clone());
        let show_saved = matched && !self.checking && cached.is_none();
        let account = if show_saved {
            self.disk.account.clone()
        } else {
            None
        };
        let error = if self.checking || show_saved {
            None
        } else if let Some(message) = cached {
            Some(message)
        } else if self.fail == Some(FailKind::Network)
            && self.failed_input.as_deref() == Some(self.disk.input.as_str())
        {
            self.note.clone()
        } else {
            match parse_target(&self.disk.input) {
                Err(text) => Some(text.to_string()),
                Ok(_) => Some("Press Enter, or leave the field, to look this up.".into()),
            }
        };
        Facts {
            account,
            error,
            checking: self.checking,
            group: self.disk.group.clone(),
            manual: self.disk.manual(),
            identity: self.identity,
            verify: self.verify,
        }
    }

    fn take_result(&mut self, result: Result<Account, LookupError>) {
        let flight = self.slot.lock().unwrap_or_else(|e| e.into_inner()).ticket;
        if flight != self.ticket {
            self.finish_flight(None);
            return;
        }
        self.finish_flight(Some(result));
    }

    fn finish_flight(&mut self, result: Option<Result<Account, LookupError>>) {
        self.checking = false;
        if let Some(result) = result {
            self.apply(result);
        }
        if let Some(input) = self.pending.take() {
            self.lookup_input(&input);
        }
    }

    fn apply(&mut self, result: Result<Account, LookupError>) {
        match result {
            Ok(account) => {
                if self
                    .disk
                    .account
                    .as_ref()
                    .is_some_and(|old| !same_saved(old, &account))
                {
                    self.disk.create_app = false;
                    self.disk.install = false;
                    self.disk.private_key = false;
                    self.disk.runner_group = false;
                    self.disk.fork_policy = false;
                }
                self.note = None;
                self.fail = None;
                self.failed_input = None;
                self.net_tries = 0;
                self.next_retry = None;
                if !self.queried.is_empty() {
                    self.remembered.remove(self.queried.trim());
                }
                self.disk.account = Some(account);
            }
            Err(err) => {
                let failed = if self.queried.is_empty() {
                    self.disk.input.clone()
                } else {
                    self.queried.clone()
                };
                self.note = Some(err.message.clone());
                self.fail = Some(err.kind);
                if err.kind == FailKind::Network {
                    self.failed_input = Some(failed);
                    self.net_tries = self.net_tries.saturating_add(1);
                    self.next_retry = Some(Instant::now() + backoff(self.net_tries));
                } else {
                    self.failed_input = None;
                    self.next_retry = None;
                    if remembers(err.kind) {
                        self.remembered.insert(
                            failed.trim().to_string(),
                            (err.kind, err.message, err.until),
                        );
                    }
                }
            }
        }
        save_disk(&self.path, &self.disk);
    }

    fn spawn(&mut self, parsed: Parsed) {
        self.ticket = self.ticket.wrapping_add(1);
        let ticket = self.ticket;
        {
            let mut slot = self.slot.lock().unwrap_or_else(|e| e.into_inner());
            slot.ticket = ticket;
            slot.done = None;
        }
        #[cfg(test)]
        if HOLD_SPAWN.with(|flag| flag.get()) {
            SPAWNS.with(|n| n.set(n.get() + 1));
            return;
        }
        let slot = Arc::clone(&self.slot);
        thread::spawn(move || {
            let result = resolve(&parsed);
            let mut guard = slot.lock().unwrap_or_else(|e| e.into_inner());
            if guard.ticket == ticket {
                guard.done = Some((ticket, result));
            }
        });
    }
}

fn same_target(parsed: &Parsed, account: &Account) -> bool {
    if !parsed.owner.eq_ignore_ascii_case(&account.login) {
        return false;
    }
    match (&parsed.repo, &account.repo) {
        (None, None) => true,
        (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
        _ => false,
    }
}

fn same_saved(a: &Account, b: &Account) -> bool {
    a.login.eq_ignore_ascii_case(&b.login)
        && match (&a.repo, &b.repo) {
            (None, None) => true,
            (Some(x), Some(y)) => x.eq_ignore_ascii_case(y),
            _ => false,
        }
}

fn rate_error(http: &Http) -> Option<LookupError> {
    let limited = http.status == 429
        || (http.status != 200
            && http.status != 404
            && http.body.to_ascii_lowercase().contains("rate limit"));
    if !limited {
        return None;
    }
    Some(LookupError::rate_limit(http.rate_until))
}

/// Without a usable header the limit is held this long.
const RATE_DEFAULT: Duration = Duration::from_secs(60);
/// No header may hold the limit longer than this.
const RATE_CAP: Duration = Duration::from_secs(3600);

/// Retry-After (delta-seconds or an HTTP-date) wins over X-RateLimit-Reset (unix seconds).
/// Garbage or no header gives `now + 60 s`; any value is capped at `now + 1 h`.
fn rate_until(retry_after: Option<&str>, reset: Option<&str>, now: SystemTime) -> SystemTime {
    let now_unix = now.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let retry_after = retry_after.map(str::trim);
    let unix = match retry_after.and_then(|s| s.parse::<u64>().ok()) {
        Some(secs) => now_unix.saturating_add(secs),
        None => retry_after
            .and_then(http_date_unix)
            .or_else(|| reset.and_then(|s| s.trim().parse::<u64>().ok()))
            .unwrap_or(now_unix + RATE_DEFAULT.as_secs()),
    };
    UNIX_EPOCH + Duration::from_secs(unix.min(now_unix + RATE_CAP.as_secs()))
}

/// Unix seconds of an RFC 7231 IMF-fixdate, e.g. `Wed, 21 Oct 2015 07:28:00 GMT`. Anything else is `None`.
fn http_date_unix(text: &str) -> Option<u64> {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let parts: Vec<&str> = text.split_ascii_whitespace().collect();
    let &[_weekday, day, month, year, time, "GMT"] = parts.as_slice() else {
        return None;
    };
    let day: i64 = day.parse().ok().filter(|d| (1..=31).contains(d))?;
    let month = MONTHS.iter().position(|m| *m == month)? as i64 + 1;
    let year: i64 = year.parse().ok().filter(|y| (1970..=9999).contains(y))?;
    let mut hms = time.split(':').map(|p| p.parse::<i64>().ok());
    let (Some(Some(h)), Some(Some(m)), Some(Some(s)), None) =
        (hms.next(), hms.next(), hms.next(), hms.next())
    else {
        return None;
    };
    if h > 23 || m > 59 || s > 60 {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let (y, mo) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * mo + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + m * 60 + s).ok()
}

fn resolve(parsed: &Parsed) -> Result<Account, LookupError> {
    let user = http_get(&format!("/users/{}", parsed.owner))?;
    if let Some(err) = rate_error(&user) {
        return Err(err);
    }
    let repo = match &parsed.repo {
        None => None,
        Some(name) => {
            let got = http_get(&format!("/repos/{}/{}", parsed.owner, name))?;
            if let Some(err) = rate_error(&got) {
                return Err(err);
            }
            Some((got.status, got.body, name.clone()))
        }
    };
    account_from(
        user.status,
        &user.body,
        repo.as_ref()
            .map(|(status, body, name)| (*status, body.as_str(), name.as_str())),
    )
}

struct Http {
    status: u16,
    body: String,
    rate_until: SystemTime,
}

enum FetchFail {
    Network(String),
    TooLarge,
    NotUtf8,
}

impl From<String> for FetchFail {
    fn from(message: String) -> Self {
        FetchFail::Network(message)
    }
}

impl From<&str> for FetchFail {
    fn from(message: &str) -> Self {
        FetchFail::Network(message.to_string())
    }
}

fn lookup_from_fetch(err: FetchFail) -> LookupError {
    match err {
        FetchFail::TooLarge => LookupError::new(FailKind::Body, "GitHub response is too large"),
        FetchFail::NotUtf8 => LookupError::new(FailKind::Body, "GitHub response was not UTF-8"),
        FetchFail::Network(message) => LookupError::new(FailKind::Network, message),
    }
}

fn http_get(path: &str) -> Result<Http, LookupError> {
    if !github_path_ok(path) {
        return Err(LookupError::new(
            FailKind::Other,
            "refusing the request path",
        ));
    }
    unsafe { winhttp_get(path) }.map_err(lookup_from_fetch)
}

fn github_path_ok(path: &str) -> bool {
    let Some(rest) = path
        .strip_prefix("/users/")
        .or_else(|| path.strip_prefix("/repos/"))
    else {
        return false;
    };
    let mut parts = rest.split('/');
    let first = parts.next().unwrap_or("");
    let second = parts.next();
    if parts.next().is_some() || !slug(first) {
        return false;
    }
    if path.starts_with("/users/") {
        return second.is_none();
    }
    matches!(second, Some(repo) if repo_name(repo))
}

/// # Safety
/// `path` must already have passed `github_path_ok`. Handles opened here are closed by
/// `Handle` on every return, including errors. The strings passed in are null-terminated
/// and live for the call.
unsafe fn winhttp_get(path: &str) -> Result<Http, FetchFail> {
    use std::ffi::c_void;
    use windows::Win32::Networking::WinHttp::{
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_FLAG_SECURE, WINHTTP_OPTION_REDIRECT_POLICY,
        WINHTTP_OPTION_REDIRECT_POLICY_NEVER, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
        WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryHeaders, WinHttpReadData,
        WinHttpReceiveResponse, WinHttpSendRequest, WinHttpSetOption, WinHttpSetTimeouts,
    };
    use windows::core::PCWSTR;
    let agent: Vec<u16> = "aap-runner-tray"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `agent` is null-terminated for this call. Null proxy names select the default.
    let session = unsafe {
        WinHttpOpen(
            PCWSTR::from_raw(agent.as_ptr()),
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        )
    };
    if session.is_null() {
        return Err(FetchFail::Network(format!(
            "could not open WinHTTP ({})",
            std::io::Error::last_os_error()
        )));
    }
    let _session = Handle(session);
    unsafe {
        let _ = WinHttpSetTimeouts(session, 10_000, 10_000, 10_000, 10_000);
    }
    let host: Vec<u16> = "api.github.com"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `session` is open and `host` is null-terminated.
    let connect = unsafe { WinHttpConnect(session, PCWSTR::from_raw(host.as_ptr()), 443, 0) };
    if connect.is_null() {
        return Err("could not connect to api.github.com".into());
    }
    let _connect = Handle(connect);
    let object: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let verb: Vec<u16> = "GET".encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: handles and wide strings live for the call. SECURE is TLS to port 443.
    let request = unsafe {
        WinHttpOpenRequest(
            connect,
            PCWSTR::from_raw(verb.as_ptr()),
            PCWSTR::from_raw(object.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null::<PCWSTR>(),
            WINHTTP_FLAG_SECURE,
        )
    };
    if request.is_null() {
        return Err("could not open the request".into());
    }
    let _request = Handle(request);
    let never = WINHTTP_OPTION_REDIRECT_POLICY_NEVER.to_ne_bytes();
    unsafe {
        let _ = WinHttpSetOption(
            Some(request.cast()),
            WINHTTP_OPTION_REDIRECT_POLICY,
            Some(&never),
        );
    }
    let headers: Vec<u16> =
        "User-Agent: aap-runner-tray\r\nAccept: application/vnd.github+json\r\n"
            .encode_utf16()
            .collect();
    unsafe {
        WinHttpSendRequest(request, Some(&headers), None, 0, 0, 0).map_err(|e| e.to_string())?;
        WinHttpReceiveResponse(request, std::ptr::null_mut()).map_err(|e| e.to_string())?;
    }
    let mut status = 0u32;
    let mut len = std::mem::size_of::<u32>() as u32;
    let mut index = 0u32;
    unsafe {
        WinHttpQueryHeaders(
            request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some((&raw mut status).cast::<c_void>()),
            &mut len,
            &mut index,
        )
        .map_err(|e| e.to_string())?;
    }
    let mut body = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let mut read = 0u32;
        unsafe {
            WinHttpReadData(
                request,
                buf.as_mut_ptr().cast(),
                buf.len() as u32,
                &mut read,
            )
            .map_err(|e| e.to_string())?;
        }
        if read == 0 {
            break;
        }
        body.extend_from_slice(&buf[..read as usize]);
        if body.len() > 64 * 1024 {
            return Err(FetchFail::TooLarge);
        }
    }
    let body = String::from_utf8(body).map_err(|_| FetchFail::NotUtf8)?;
    let retry_after = header_text(request, "Retry-After");
    let reset = header_text(request, "X-RateLimit-Reset");
    let rate_until = rate_until(retry_after.as_deref(), reset.as_deref(), SystemTime::now());
    Ok(Http {
        status: status as u16,
        body,
        rate_until,
    })
}

/// The trimmed value of a response header, or `None` when absent or empty.
fn header_text(request: *mut std::ffi::c_void, name: &str) -> Option<String> {
    use windows::Win32::Networking::WinHttp::WinHttpQueryHeaders;
    use windows::core::PCWSTR;
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let mut buf = vec![0u16; 64];
    let mut len = (buf.len() * 2) as u32;
    let mut index = 0u32;
    let ok = unsafe {
        WinHttpQueryHeaders(
            request,
            65535,
            PCWSTR::from_raw(wide.as_ptr()),
            Some(buf.as_mut_ptr().cast()),
            &mut len,
            &mut index,
        )
    };
    if ok.is_err() {
        return None;
    }
    let chars = (len as usize / 2).min(buf.len());
    let text = String::from_utf16_lossy(&buf[..chars]);
    let text = text.trim_end_matches('\0').trim();
    (!text.is_empty()).then(|| text.to_string())
}

struct Handle(*mut std::ffi::c_void);
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = windows::Win32::Networking::WinHttp::WinHttpCloseHandle(self.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn org(public_repos: u64) -> Account {
        Account {
            login: "acme".into(),
            kind: Kind::Org,
            repo: None,
            repo_verified: true,
            public_repos,
        }
    }
    fn user() -> Account {
        Account {
            login: "octocat".into(),
            kind: Kind::User,
            repo: Some("hello".into()),
            repo_verified: true,
            public_repos: 2,
        }
    }
    fn facts(account: Option<Account>, manual: Manual) -> Facts {
        Facts {
            account,
            error: None,
            checking: false,
            group: GROUP_DEFAULT.into(),
            manual,
            identity: Identity::default(),
            verify: Verify::default(),
        }
    }
    fn phase(list: &[Row], id: RowId) -> Phase {
        list.iter().find(|r| r.id == id).unwrap().phase
    }

    #[test]
    fn links_follow_the_owner_kind() {
        let org = links(Kind::Org, "acme").unwrap();
        assert_eq!(
            org.create_app,
            "https://github.com/organizations/acme/settings/apps/new?public=false&webhook_active=false&organization_self_hosted_runners=write&actions=read"
        );
        assert_eq!(
            org.apps,
            "https://github.com/organizations/acme/settings/apps"
        );
        assert_eq!(
            org.install_pattern,
            "https://github.com/organizations/acme/settings/apps/<app>/installations"
        );
        assert_eq!(
            org.runner_groups.as_deref(),
            Some("https://github.com/organizations/acme/settings/actions/runner-groups")
        );
        assert_eq!(
            org.actions,
            "https://github.com/organizations/acme/settings/actions"
        );
        assert!(links(Kind::User, "octocat").is_none());
        assert!(links(Kind::Org, "bad/name").is_none());
    }

    #[test]
    fn injected_responses_tell_org_from_user_and_a_missing_repo() {
        let org = account_from(
            200,
            r#"{"login":"acme","type":"Organization","public_repos":4}"#,
            None,
        )
        .unwrap();
        assert_eq!(org.kind, Kind::Org);
        assert_eq!(org.public_repos, 4);
        let user = account_from(
            200,
            r#"{"login":"octocat","type":"User","public_repos":8}"#,
            Some((200, r#"{"name":"hello"}"#, "hello")),
        )
        .unwrap();
        assert_eq!(user.kind, Kind::User);
        assert_eq!(user.repo.as_deref(), Some("hello"));
        let missing = account_from(404, r#"{"message":"Not Found"}"#, None).unwrap_err();
        assert_eq!(missing.kind, FailKind::NotFound);
        assert!(missing.message.contains("not found"));
        let limited =
            account_from(403, r#"{"message":"API rate limit exceeded"}"#, None).unwrap_err();
        assert_eq!(limited.kind, FailKind::RateLimit);
        let private = account_from(
            200,
            r#"{"login":"acme","type":"Organization","public_repos":1}"#,
            Some((404, r#"{"message":"Not Found"}"#, "secret")),
        )
        .unwrap();
        assert_eq!(private.repo.as_deref(), Some("secret"));
        assert!(!private.repo_verified);
        let listed = rows(&facts(
            Some(private),
            Manual {
                create_app: true,
                ..Manual::default()
            },
        ));
        assert_eq!(phase(&listed, RowId::Account), Phase::Met);
        assert_ne!(phase(&listed, RowId::CreateApp), Phase::Blocked);
        assert!(
            listed
                .iter()
                .find(|r| r.id == RowId::Account)
                .unwrap()
                .action
                .contains("could not be verified")
        );
    }

    #[test]
    fn a_user_account_stops_the_checklist_and_an_org_group_stays_manual() {
        let ticked = Manual {
            create_app: true,
            install: true,
            private_key: true,
            runner_group: true,
            fork_policy: true,
        };
        let list = rows(&facts(Some(user()), ticked));
        let account = list.iter().find(|r| r.id == RowId::Account).unwrap();
        assert_eq!(account.phase, Phase::Unmet);
        assert_eq!(
            account.missing,
            "Only organizations are supported; octocat is a user account."
        );
        assert!(account.action.is_empty());
        assert!(
            list.iter()
                .filter(|r| r.id != RowId::Account)
                .all(|r| r.phase == Phase::Blocked)
        );
        assert!(list.iter().all(|r| !r.action.contains("do not exist")));
        assert!(
            list.iter()
                .all(|r| !r.action.contains("Settings > Actions"))
        );
        assert!(list.iter().all(|r| {
            r.link.as_deref() != Some("https://github.com/octocat/hello/settings/actions")
        }));
        assert!(!list.iter().all(|r| r.phase == Phase::Met));
        let mut bare = user();
        bare.repo = None;
        let bare_rows = rows(&facts(Some(bare), ticked));
        assert_eq!(
            bare_rows
                .iter()
                .find(|r| r.id == RowId::Account)
                .unwrap()
                .missing,
            "Only organizations are supported; octocat is a user account."
        );
        assert!(
            bare_rows
                .iter()
                .filter(|r| r.id != RowId::Account)
                .all(|r| r.phase == Phase::Blocked)
        );
        let manual = Manual {
            create_app: true,
            install: true,
            private_key: true,
            ..Manual::default()
        };
        let org_rows = rows(&facts(Some(org(3)), manual));
        let group = org_rows.iter().find(|r| r.id == RowId::Group).unwrap();
        assert_eq!(group.phase, Phase::Unmet);
        assert!(group.action.contains("Allow public repositories"));
        assert_eq!(
            group.link.as_deref(),
            Some("https://github.com/organizations/acme/settings/actions/runner-groups")
        );
        let quiet = rows(&facts(Some(org(0)), manual));
        assert!(
            quiet
                .iter()
                .find(|r| r.id == RowId::Group)
                .unwrap()
                .action
                .contains("Allow public repositories")
        );
        let create = org_rows.iter().find(|r| r.id == RowId::CreateApp).unwrap();
        assert!(
            create
                .action
                .contains("Self-hosted runners: Read and write")
        );
        assert!(create.action.contains("Actions: Read"));
        assert!(create.action.contains("Webhook off"));
        assert!(create.action.contains("Only on this account"));
        let install = org_rows.iter().find(|r| r.id == RowId::Install).unwrap();
        assert!(install.action.contains("<app>/installations"));
        assert!(install.action.contains("App ID"));
        assert!(install.action.contains("Installation ID"));
    }

    #[test]
    fn later_rows_stay_blocked_until_the_manual_ticks_and_identity_replaces_them() {
        let list = rows(&facts(None, Manual::default()));
        assert_eq!(phase(&list, RowId::Account), Phase::Unmet);
        assert_eq!(phase(&list, RowId::CreateApp), Phase::Blocked);
        assert_eq!(first_open(&list), Some(RowId::Account));
        let list = rows(&facts(
            Some(org(1)),
            Manual {
                create_app: true,
                ..Manual::default()
            },
        ));
        assert_eq!(phase(&list, RowId::CreateApp), Phase::Met);
        assert_eq!(phase(&list, RowId::Install), Phase::Unmet);
        assert_eq!(phase(&list, RowId::Key), Phase::Blocked);
        assert_eq!(first_open(&list), Some(RowId::Install));
        let mut with_id = facts(Some(org(1)), Manual::default());
        with_id.identity.app_id = Some(42);
        with_id.identity.installation_id = Some(7);
        with_id.identity.key_present = true;
        let list = rows(&with_id);
        assert!(
            !list
                .iter()
                .find(|r| r.id == RowId::CreateApp)
                .unwrap()
                .manual
        );
        assert_eq!(phase(&list, RowId::CreateApp), Phase::Met);
        assert_eq!(phase(&list, RowId::Install), Phase::Met);
        assert_eq!(phase(&list, RowId::Key), Phase::Met);
        with_id.verify.app_authenticates = Some(false);
        let list = rows(&with_id);
        assert_eq!(phase(&list, RowId::CreateApp), Phase::Unmet);
        assert!(
            list.iter()
                .find(|r| r.id == RowId::CreateApp)
                .unwrap()
                .missing
                .contains("did not authenticate")
        );
    }

    #[test]
    fn the_workflow_line_uses_the_group_and_next_waits_for_every_tick() {
        let manual = Manual {
            create_app: true,
            install: true,
            private_key: true,
            runner_group: true,
            fork_policy: true,
        };
        let ready = rows(&facts(Some(org(1)), manual));
        assert!(ready.iter().all(|r| r.phase == Phase::Met));
        assert_eq!(
            ready
                .iter()
                .find(|r| r.id == RowId::Workflow)
                .unwrap()
                .copy
                .as_deref(),
            Some("runs-on: {group: aap-crrr, labels: [self-hosted, linux]}")
        );
        assert!(ready_to_advance(true, true, Duration::from_secs(2)));
        assert!(!ready_to_advance(true, true, Duration::from_secs(1)));
        assert!(!ready_to_advance(true, false, Duration::from_secs(5)));
        let manual = Manual {
            fork_policy: false,
            ..manual
        };
        let list = rows(&facts(Some(org(1)), manual));
        assert_eq!(phase(&list, RowId::Fork), Phase::Unmet);
        assert_eq!(phase(&list, RowId::Workflow), Phase::Blocked);
    }

    #[test]
    fn the_checklist_round_trips_and_ignores_another_schema() {
        let path = state::temp_base("github-setup").join("github-setup.json");
        save_disk(
            &path,
            &Disk {
                schema: 1,
                input: "acme".into(),
                group: "aap-crrr".into(),
                create_app: true,
                account: Some(org(2)),
                ..Disk::default()
            },
        );
        let loaded = load_disk(&path);
        assert!(loaded.create_app);
        assert_eq!(loaded.account.unwrap().login, "acme");
        std::fs::write(&path, r#"{"schema":9,"input":"nope"}"#).unwrap();
        assert!(load_disk(&path).input.is_empty());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    struct Hold;
    impl Drop for Hold {
        fn drop(&mut self) {
            super::hold_spawns(false);
        }
    }
    fn hold() -> Hold {
        super::hold_spawns(true);
        Hold
    }

    #[test]
    fn typing_does_not_look_up_until_submit_and_ticks_clear_only_when_the_account_changes() {
        let _hold = hold();
        let path = state::temp_base("gh-keys").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.disk.account = Some(org(1));
        store.disk.input = "acme".into();
        store.disk.create_app = true;
        store.set_input("othe".into());
        assert_eq!(super::spawns(), 0);
        assert!(store.disk.create_app);
        assert_eq!(store.disk.account.as_ref().unwrap().login, "acme");
        store.commit();
        assert_eq!(super::spawns(), 1);
        assert!(store.disk.create_app);
        let mut other = org(0);
        other.login = "othe".into();
        store.take_result(Ok(other));
        assert!(!store.disk.create_app);
        store.disk.create_app = true;
        let mut again = org(3);
        again.login = "othe".into();
        store.take_result(Ok(again));
        assert!(store.disk.create_app);
        store.disk.account = None;
        store.disk.create_app = true;
        store.take_result(Ok(org(1)));
        assert!(store.disk.create_app);
        store.disk.input = "acme".into();
        store.disk.account = Some(org(1));
        store.checking = false;
        let before = super::spawns();
        store.commit();
        assert_eq!(super::spawns(), before);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_not_found_or_rate_limit_is_not_retried_and_a_network_error_backs_off() {
        let _hold = hold();
        let path = state::temp_base("gh-retry").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.disk.input = "other".into();
        store.disk.account = Some(org(1));
        store.disk.create_app = true;
        store.take_result(Err(LookupError::new(
            FailKind::Network,
            "could not connect to api.github.com",
        )));
        assert!(store.disk.create_app);
        assert_eq!(store.disk.account.as_ref().unwrap().login, "acme");
        assert_eq!(store.fail, Some(FailKind::Network));
        store.retry();
        assert_eq!(super::spawns(), 0, "backoff has not elapsed");
        store.set_input("elsewhere".into());
        store.next_retry = Some(Instant::now() - Duration::from_secs(1));
        store.retry();
        assert_eq!(super::spawns(), 0, "backoff stays on the input that failed");
        store.set_input("other".into());
        store.retry();
        assert_eq!(super::spawns(), 1);
        store.checking = false;
        store.fail = Some(FailKind::NotFound);
        store.retry();
        store.fail = Some(FailKind::RateLimit);
        store.retry();
        assert_eq!(super::spawns(), 1);
        assert_eq!(backoff(1), Duration::from_secs(5));
        assert_eq!(backoff(2), Duration::from_secs(10));
        assert_eq!(backoff(3), Duration::from_secs(20));
        assert_eq!(backoff(4), Duration::from_secs(40));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_checklist_file_is_under_local_app_data() {
        let path = path();
        assert!(path.ends_with("github-setup.json"));
        assert_eq!(
            path.parent()
                .and_then(|dir| dir.file_name())
                .and_then(|n| n.to_str()),
            Some("aap-runner")
        );
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            assert!(path.starts_with(local));
        }
    }

    #[test]
    fn a_failed_submit_hides_the_saved_account_until_this_input_succeeds() {
        let _hold = hold();
        let path = state::temp_base("gh-fail").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.disk.account = Some(org(1));
        store.disk.input = "acme".into();
        store.disk.create_app = true;
        store.disk.install = true;
        store.disk.private_key = true;
        store.disk.runner_group = true;
        store.disk.fork_policy = true;
        assert!(store.rows().iter().all(|r| r.phase == Phase::Met));
        store.set_input("missing".into());
        assert!(
            !store.rows().iter().all(|r| r.phase == Phase::Met),
            "a different field is not the saved success"
        );
        store.commit();
        assert_eq!(super::spawns(), 1);
        assert_eq!(
            store
                .rows()
                .iter()
                .find(|r| r.id == RowId::Account)
                .unwrap()
                .phase,
            Phase::Checking
        );
        assert!(store.disk.create_app);
        store.take_result(Err(LookupError::new(
            FailKind::NotFound,
            "That account was not found.",
        )));
        let account = store
            .rows()
            .into_iter()
            .find(|r| r.id == RowId::Account)
            .unwrap();
        assert_eq!(account.phase, Phase::Unmet);
        assert_eq!(account.missing, "That account was not found.");
        assert!(store.rows().iter().any(|r| r.phase == Phase::Blocked));
        assert!(!store.rows().iter().all(|r| r.phase == Phase::Met));
        assert!(store.disk.create_app);
        assert!(store.disk.fork_policy);
        let spawned = super::spawns();
        store.commit();
        assert_eq!(super::spawns(), spawned);
        store.set_input("acme".into());
        store.commit();
        assert_eq!(super::spawns(), spawned);
        assert!(store.rows().iter().all(|r| r.phase == Phase::Met));
        assert!(store.disk.create_app);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_submit_during_a_lookup_runs_when_that_lookup_finishes() {
        let _hold = hold();
        let path = state::temp_base("gh-pending").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.disk.account = Some(org(1));
        store.disk.input = "acme".into();
        store.disk.create_app = true;
        store.set_input("other".into());
        store.commit();
        assert_eq!(super::spawns(), 1);
        store.set_input("third".into());
        store.commit();
        store.set_input("fourth".into());
        store.commit();
        assert_eq!(super::spawns(), 1);
        let mut other = org(0);
        other.login = "other".into();
        store.take_result(Ok(other));
        assert_eq!(super::spawns(), 2);
        assert!(store.disk.create_app);
        assert_eq!(store.disk.account.as_ref().unwrap().login, "acme");
        assert!(store.checking);
        let mut fourth = org(0);
        fourth.login = "fourth".into();
        store.take_result(Ok(fourth));
        assert_eq!(store.disk.account.as_ref().unwrap().login, "fourth");
        assert!(!store.disk.create_app);
        assert_eq!(super::spawns(), 2);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_resolved_user_stops_before_create_app() {
        let _hold = hold();
        let path = state::temp_base("gh-user").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.disk.create_app = true;
        store.disk.fork_policy = true;
        store.set_input("octocat/hello".into());
        store.commit();
        store.take_result(Ok(user()));
        let rows = store.rows();
        let account = rows.iter().find(|r| r.id == RowId::Account).unwrap();
        assert_eq!(account.phase, Phase::Unmet);
        assert_eq!(
            account.missing,
            "Only organizations are supported; octocat is a user account."
        );
        assert!(
            rows.iter()
                .filter(|r| r.id != RowId::Account)
                .all(|r| r.phase == Phase::Blocked)
        );
        assert!(store.disk.create_app);
        assert!(!rows.iter().any(|r| r.action.contains("do not exist")));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_final_failure_is_remembered_per_input_and_a_bad_body_is_not_retried() {
        let _hold = hold();
        let path = state::temp_base("gh-memory").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.set_input("missing".into());
        store.commit();
        assert_eq!(super::spawns(), 1);
        store.take_result(Err(LookupError::new(
            FailKind::NotFound,
            "That account was not found.",
        )));
        store.commit();
        assert_eq!(super::spawns(), 1, "the same 404 text is not queried again");
        store.set_input("limited".into());
        store.commit();
        assert_eq!(super::spawns(), 2);
        store.take_result(Err(LookupError::new(
            FailKind::RateLimit,
            "GitHub rate limit. Try again later.",
        )));
        store.commit();
        assert_eq!(
            super::spawns(),
            2,
            "the same rate-limit text is not queried again"
        );
        store.set_input("missing".into());
        store.commit();
        assert_eq!(super::spawns(), 2, "the earlier 404 is still remembered");
        assert_eq!(
            store
                .rows()
                .iter()
                .find(|r| r.id == RowId::Account)
                .unwrap()
                .missing,
            "That account was not found."
        );
        store.set_input("huge".into());
        store.commit();
        assert_eq!(super::spawns(), 3);
        store.take_result(Err(lookup_from_fetch(FetchFail::TooLarge)));
        assert_eq!(store.fail, Some(FailKind::Body));
        store.retry();
        store.commit();
        assert_eq!(
            super::spawns(),
            3,
            "an unusable body is not retried or re-queried"
        );
        store.set_input("odd".into());
        store.commit();
        let spawned = super::spawns();
        store.take_result(Err(lookup_from_fetch(FetchFail::NotUtf8)));
        store.retry();
        store.commit();
        assert_eq!(super::spawns(), spawned);
        assert_eq!(
            lookup_from_fetch(FetchFail::Network("GitHub response is too large".into())).kind,
            FailKind::Network
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn retry_after_seconds_beat_the_reset_time() {
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        assert_eq!(
            rate_until(Some("90"), Some("1700000900"), now),
            now + Duration::from_secs(90)
        );
        assert_eq!(
            rate_until(None, Some("1700000090"), now),
            UNIX_EPOCH + Duration::from_secs(1_700_000_090)
        );
        let bare = rate_error(&Http {
            status: 429,
            body: String::new(),
            rate_until: now,
        })
        .unwrap();
        assert_eq!(bare.kind, FailKind::RateLimit);
        assert_eq!(bare.until, Some(now));
    }

    #[test]
    fn a_missing_or_garbage_header_holds_the_limit_for_60_s() {
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let in_60 = now + Duration::from_secs(60);
        assert_eq!(rate_until(None, None, now), in_60);
        assert_eq!(rate_until(Some(""), Some(" "), now), in_60);
        assert_eq!(rate_until(Some("soon"), Some("-5"), now), in_60);
        assert_eq!(
            rate_until(Some("Wed, 21 Oct 2015 07:28:00"), None, now),
            in_60
        );
        assert_eq!(
            rate_until(Some("Wed, 32 Oct 2015 07:28:00 GMT"), None, now),
            in_60
        );
        assert_eq!(
            rate_until(Some("Wed, 21 Oct 2015 24:00:00 GMT"), None, now),
            in_60
        );
    }

    #[test]
    fn an_http_date_retry_after_is_parsed() {
        assert_eq!(
            http_date_unix("Wed, 21 Oct 2015 07:28:00 GMT"),
            Some(1_445_412_480)
        );
        assert_eq!(http_date_unix("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
        assert_eq!(
            http_date_unix("Tue, 29 Feb 2000 12:00:00 GMT"),
            Some(951_825_600)
        );
        assert_eq!(
            http_date_unix("Sun, 06 Nov 1994 08:49:37 GMT"),
            Some(784_111_777)
        );
        let now = UNIX_EPOCH + Duration::from_secs(1_445_412_000);
        assert_eq!(
            rate_until(
                Some("Wed, 21 Oct 2015 07:28:00 GMT"),
                Some("1445413000"),
                now
            ),
            UNIX_EPOCH + Duration::from_secs(1_445_412_480),
            "the date beats the reset header"
        );
    }

    #[test]
    fn a_reset_is_capped_at_one_hour_out() {
        let now = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let in_1h = now + Duration::from_secs(3600);
        assert_eq!(rate_until(None, Some("1800000000"), now), in_1h);
        assert_eq!(rate_until(Some("86400"), None, now), in_1h);
        assert_eq!(
            rate_until(Some("Fri, 01 Jan 2100 00:00:00 GMT"), None, now),
            in_1h
        );
        assert_eq!(
            rate_until(Some(u64::MAX.to_string().as_str()), None, now),
            in_1h
        );
        assert_eq!(
            rate_until(Some("3599"), None, now),
            now + Duration::from_secs(3599)
        );
    }

    #[test]
    fn try_again_at_is_shown_in_local_time() {
        let at = UNIX_EPOCH + Duration::from_secs(1_445_412_480); // 07:28 UTC
        assert_eq!(try_again_at(at, 0), "try again at 07:28");
        assert_eq!(try_again_at(at, 2 * 3600), "try again at 09:28");
        assert_eq!(try_again_at(at, -8 * 3600), "try again at 23:28");
    }

    #[test]
    fn a_rate_limit_expires_and_until_then_focus_loss_does_not_query() {
        let _hold = hold();
        let path = state::temp_base("gh-rate").join("github-setup.json");
        let mut store = Store::load(path.clone());
        store.set_input("limited".into());
        store.commit();
        let spawned = super::spawns();
        let until = SystemTime::now() + Duration::from_secs(3600);
        store.take_result(Err(LookupError::rate_limit(until)));
        let missing = store
            .rows()
            .into_iter()
            .find(|r| r.id == RowId::Account)
            .unwrap()
            .missing;
        assert!(missing.starts_with("try again at "), "{missing}");
        store.commit();
        assert_eq!(super::spawns(), spawned, "focus loss does not re-query yet");
        store.take_result(Err(LookupError::rate_limit(
            SystemTime::now() - Duration::from_secs(5),
        )));
        store.commit();
        assert_eq!(super::spawns(), spawned + 1, "the rate limit has expired");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn empty_localappdata_uses_the_temp_dir() {
        let temp = std::path::PathBuf::from("T");
        let file = std::path::Path::new("aap-runner").join("github-setup.json");
        let name = "github-setup.json";
        assert_eq!(data_path(None, temp.clone(), name), temp.join(&file));
        assert_eq!(
            data_path(Some(std::ffi::OsString::new()), temp.clone(), name),
            temp.join(&file)
        );
        assert_eq!(
            data_path(Some("C:\\AppData\\Local".into()), temp, name),
            std::path::PathBuf::from("C:\\AppData\\Local").join(file)
        );
    }
}
