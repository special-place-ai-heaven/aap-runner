//! GitHub setup checklist. The public API answers who the owner is. No token is
//! read, sent, or stored. A row the app cannot see yet stays a manual tick until
//! a later input (the identity page) makes it checkable.
//!
//! ponytail: fork policy has no check, so an organization still ticks that row.
//! M3 passes Identity and Verify into `rows`; this page leaves both empty.

use crate::state;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const ADVANCE_AFTER: Duration = Duration::from_secs(2);
pub const GROUP_DEFAULT: &str = "aap-crrr";
const APP_PERMS: &str = "Required permissions: Organization > Self-hosted runners: Read and write; Repository > Actions: Read. Webhook off. Choose Only on this account.";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Org,
    User,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub login: String,
    pub kind: Kind,
    pub repo: Option<String>,
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
    if !slug(login) {
        return None;
    }
    Some(match kind {
        Kind::Org => Links {
            create_app: format!("https://github.com/organizations/{login}/settings/apps/new"),
            apps: format!("https://github.com/organizations/{login}/settings/apps"),
            install_pattern: format!(
                "https://github.com/organizations/{login}/settings/apps/<app>/installations"
            ),
            runner_groups: Some(format!(
                "https://github.com/organizations/{login}/settings/actions/runner-groups"
            )),
            actions: format!("https://github.com/organizations/{login}/settings/actions"),
        },
        Kind::User => Links {
            create_app: "https://github.com/settings/apps/new".into(),
            apps: "https://github.com/settings/apps".into(),
            install_pattern: "https://github.com/settings/apps/<app>/installations".into(),
            runner_groups: None,
            actions: format!("https://github.com/{login}"),
        },
    })
}

pub fn workflow(kind: Kind, group: &str) -> String {
    match kind {
        Kind::Org => format!(
            "runs-on: {{group: {}, labels: [self-hosted, linux]}}",
            group.trim()
        ),
        Kind::User => "runs-on: [self-hosted, linux]".into(),
    }
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
    failed: Option<bool>,
    known: bool,
    ticked: bool,
    fail: &'static str,
    missing: &'static str,
    action: String,
    link: Option<String>,
}

fn decided(c: Check) -> Row {
    if c.failed == Some(false) {
        return row(c.id, c.title, Phase::Unmet, false, c.fail, c.action, c.link);
    }
    if c.known || c.failed == Some(true) {
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
            failed: facts.verify.app_authenticates,
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
            failed: facts.verify.installation_matches,
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
            failed: None,
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
    let group = group_row(facts, key.phase == Phase::Met, kind, linked.as_ref());
    let fork = fork_row(facts, group.phase == Phase::Met, kind, linked.as_ref());
    let flow = workflow_row(facts, fork.phase == Phase::Met, kind);
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
        let where_ = match &account.repo {
            Some(repo) => format!("{}/{}", account.login, repo),
            None => account.login.clone(),
        };
        let kind = match account.kind {
            Kind::Org => "an organization",
            Kind::User => "a user",
        };
        return row(
            RowId::Account,
            "Account",
            Phase::Met,
            false,
            "",
            format!("{where_} is {kind}."),
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

fn group_row(facts: &Facts, prev: bool, kind: Option<Kind>, links: Option<&Links>) -> Row {
    if !prev {
        return blocked(RowId::Group, "Runner group");
    }
    if kind == Some(Kind::User) {
        return row(
            RowId::Group,
            "Runner group",
            Phase::Met,
            false,
            "",
            "Runner groups do not exist on a personal account. Runners register per repository.",
            None,
        );
    }
    let link = links.and_then(|l| l.runner_groups.clone());
    let public = facts.account.as_ref().is_some_and(|a| a.public_repos > 0);
    let allow = if public {
        " Tick Allow public repositories, then add the repositories."
    } else {
        " Add the repositories that should use this group."
    };
    let action = format!("Create the group (default name {GROUP_DEFAULT}).{allow}");
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

fn fork_row(facts: &Facts, prev: bool, kind: Option<Kind>, links: Option<&Links>) -> Row {
    if !prev {
        return blocked(RowId::Fork, "Fork policy");
    }
    if kind == Some(Kind::User) {
        let link = facts.account.as_ref().and_then(|a| {
            a.repo
                .as_ref()
                .map(|repo| format!("https://github.com/{}/{repo}/settings/actions", a.login))
        });
        return row(
            RowId::Fork,
            "Fork policy",
            Phase::Met,
            false,
            "",
            "A personal account has no organization Actions policy page. When a repository was given, its Actions settings are the place to require approval.",
            link,
        );
    }
    let link = links.map(|l| l.actions.clone());
    if facts.manual.fork_policy {
        row(
            RowId::Fork,
            "Fork policy",
            Phase::Met,
            true,
            "",
            "Require approval for all outside collaborators.",
            link,
        )
    } else {
        row(
            RowId::Fork,
            "Fork policy",
            Phase::Unmet,
            true,
            "Outside collaborators can still run workflows without approval.",
            "Require approval for all outside collaborators.",
            link,
        )
    }
}

fn workflow_row(facts: &Facts, prev: bool, kind: Option<Kind>) -> Row {
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
    r.copy = Some(workflow(kind.unwrap_or(Kind::Org), &facts.group));
    r
}

pub fn first_open(list: &[Row]) -> Option<RowId> {
    list.iter()
        .find(|r| r.phase == Phase::Unmet || r.phase == Phase::Checking)
        .map(|r| r.id)
}

pub fn account_from(
    user_status: u16,
    user_body: &str,
    repo: Option<(u16, &str)>,
) -> Result<Account, String> {
    let user = interpret_user(user_status, user_body)?;
    let repo = match repo {
        None => None,
        Some((status, body)) => Some(interpret_repo(status, body)?),
    };
    if !slug(&user.login) {
        return Err("GitHub returned an unexpected login.".into());
    }
    Ok(Account {
        login: user.login,
        kind: user.kind,
        repo,
        public_repos: user.public_repos,
    })
}

struct UserHit {
    login: String,
    kind: Kind,
    public_repos: u64,
}

fn interpret_user(status: u16, body: &str) -> Result<UserHit, String> {
    if status == 404 {
        return Err("That account was not found.".into());
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
        .map_err(|_| "GitHub returned an unexpected account.".to_string())?;
    let kind = match body.kind.as_str() {
        "Organization" => Kind::Org,
        "User" => Kind::User,
        _ => return Err("GitHub returned an unexpected account type.".into()),
    };
    Ok(UserHit {
        login: body.login,
        kind,
        public_repos: body.public_repos.unwrap_or(0),
    })
}

fn interpret_repo(status: u16, body: &str) -> Result<String, String> {
    if status == 404 {
        return Err("That repository was not found, or it is private. The public API cannot see a private repository.".into());
    }
    if status != 200 {
        return Err(status_error(status, body));
    }
    #[derive(Deserialize)]
    struct Body {
        name: String,
    }
    let body: Body = serde_json::from_str(body)
        .map_err(|_| "GitHub returned an unexpected repository.".to_string())?;
    if !repo_name(&body.name) {
        return Err("GitHub returned an unexpected repository name.".into());
    }
    Ok(body.name)
}

fn status_error(status: u16, body: &str) -> String {
    if body.to_ascii_lowercase().contains("rate limit") {
        "GitHub rate limit. The lookup will retry.".into()
    } else {
        format!("GitHub returned {status}.")
    }
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
    crate::history::History::path().with_file_name("github-setup.json")
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
    if let Ok(text) = serde_json::to_vec(disk) {
        let _ = state::write_atomic(path, &text);
    }
}

struct Slot {
    ticket: u64,
    done: Option<(u64, Result<Account, String>)>,
}

pub struct Store {
    path: PathBuf,
    disk: Disk,
    note: Option<String>,
    checking: bool,
    slot: Arc<Mutex<Slot>>,
    ticket: u64,
}

impl Store {
    pub fn load(path: PathBuf) -> Self {
        Self {
            disk: load_disk(&path),
            path,
            note: None,
            checking: false,
            slot: Arc::new(Mutex::new(Slot {
                ticket: 0,
                done: None,
            })),
            ticket: 0,
        }
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
        match parse_target(&self.disk.input) {
            Ok(parsed)
                if self
                    .disk
                    .account
                    .as_ref()
                    .is_some_and(|a| same_target(&parsed, a)) =>
            {
                self.checking = false
            }
            Ok(parsed) => {
                self.disk.account = None;
                self.disk.create_app = false;
                self.disk.install = false;
                self.disk.private_key = false;
                self.disk.runner_group = false;
                self.disk.fork_policy = false;
                self.note = None;
                self.checking = true;
                self.spawn(parsed);
            }
            Err(_) => {
                self.disk.account = None;
                self.checking = false;
                self.note = None;
            }
        }
        save_disk(&self.path, &self.disk);
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

    /// Start a lookup when the page is open and the cached answer is missing.
    pub fn retry(&mut self) {
        if self.checking || self.disk.account.is_some() {
            return;
        }
        let Ok(parsed) = parse_target(&self.disk.input) else {
            return;
        };
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
            return;
        }
        self.checking = false;
        match result {
            Ok(account) => {
                self.note = None;
                self.disk.account = Some(account);
            }
            Err(err) => {
                self.note = Some(err);
                self.disk.account = None;
            }
        }
        save_disk(&self.path, &self.disk);
    }

    pub fn rows(&self) -> Vec<Row> {
        rows(&self.facts())
    }

    fn facts(&self) -> Facts {
        let error = if self.disk.account.is_none() && !self.checking {
            match parse_target(&self.disk.input) {
                Err(text) => Some(text.to_string()),
                Ok(_) => self
                    .note
                    .clone()
                    .or_else(|| Some("The lookup failed.".into())),
            }
        } else {
            None
        };
        Facts {
            account: self.disk.account.clone(),
            error,
            checking: self.checking,
            group: self.disk.group.clone(),
            manual: self.disk.manual(),
            identity: Identity::default(),
            verify: Verify::default(),
        }
    }

    fn spawn(&mut self, parsed: Parsed) {
        self.ticket = self.ticket.wrapping_add(1);
        let ticket = self.ticket;
        {
            let mut slot = self.slot.lock().unwrap_or_else(|e| e.into_inner());
            slot.ticket = ticket;
            slot.done = None;
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

fn resolve(parsed: &Parsed) -> Result<Account, String> {
    let user = http_get(&format!("/users/{}", parsed.owner))?;
    let repo = match &parsed.repo {
        None => None,
        Some(repo) => {
            let got = http_get(&format!("/repos/{}/{}", parsed.owner, repo))?;
            Some((got.status, got.body))
        }
    };
    account_from(
        user.status,
        &user.body,
        repo.as_ref().map(|(s, b)| (*s, b.as_str())),
    )
}

struct Http {
    status: u16,
    body: String,
}

fn http_get(path: &str) -> Result<Http, String> {
    if !github_path_ok(path) {
        return Err("refusing the request path".into());
    }
    unsafe { winhttp_get(path) }
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

unsafe fn winhttp_get(path: &str) -> Result<Http, String> {
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
        return Err(format!(
            "could not open WinHTTP ({})",
            std::io::Error::last_os_error()
        ));
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
            return Err("GitHub response is too large".into());
        }
    }
    let body = String::from_utf8(body).map_err(|_| "GitHub response was not UTF-8".to_string())?;
    Ok(Http {
        status: status as u16,
        body,
    })
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
            public_repos,
        }
    }
    fn user() -> Account {
        Account {
            login: "octocat".into(),
            kind: Kind::User,
            repo: Some("hello".into()),
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
            "https://github.com/organizations/acme/settings/apps/new"
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
        let user = links(Kind::User, "octocat").unwrap();
        assert_eq!(user.create_app, "https://github.com/settings/apps/new");
        assert_eq!(user.apps, "https://github.com/settings/apps");
        assert_eq!(
            user.install_pattern,
            "https://github.com/settings/apps/<app>/installations"
        );
        assert!(user.runner_groups.is_none());
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
            Some((200, r#"{"name":"hello"}"#)),
        )
        .unwrap();
        assert_eq!(user.kind, Kind::User);
        assert_eq!(user.repo.as_deref(), Some("hello"));
        assert!(
            account_from(404, r#"{"message":"Not Found"}"#, None)
                .unwrap_err()
                .contains("not found")
        );
        let private = account_from(
            200,
            r#"{"login":"octocat","type":"User","public_repos":1}"#,
            Some((404, r#"{"message":"Not Found"}"#)),
        )
        .unwrap_err();
        assert!(private.contains("private"));
    }

    #[test]
    fn a_user_owner_skips_groups_and_an_org_with_public_repos_says_so() {
        let manual = Manual {
            create_app: true,
            install: true,
            private_key: true,
            ..Manual::default()
        };
        let list = rows(&facts(Some(user()), manual));
        assert_eq!(phase(&list, RowId::Group), Phase::Met);
        assert!(
            list.iter()
                .find(|r| r.id == RowId::Group)
                .unwrap()
                .action
                .contains("do not exist")
        );
        assert_eq!(phase(&list, RowId::Fork), Phase::Met);
        assert_eq!(
            list.iter()
                .find(|r| r.id == RowId::Workflow)
                .unwrap()
                .copy
                .as_deref(),
            Some("runs-on: [self-hosted, linux]")
        );
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
            !quiet
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
}
