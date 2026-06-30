// SPDX-License-Identifier: GPL-3.0-or-later

use crate::error::{HelperError, Result};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message, WebSocket};

const YTM_ORIGIN: &str = "https://music.youtube.com";
const YTM_ORIGIN_ENCODED: &str = "https%3A%2F%2Fmusic.youtube.com";
#[cfg(target_os = "macos")]
const DEFAULT_DIA_LOGIN_BROWSER_PATH: &str = "/Applications/Dia.app/Contents/MacOS/Dia";
const LOGIN_BROWSER_CHOICES: &str =
    "chrome, brave, edge, chromium, firefox, zen, dia, or an executable path";
const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const YTM_SESSION_EXPRESSION: &str = r#"
(() => {
  const get = (name) => {
    try {
      if (globalThis.ytcfg && typeof globalThis.ytcfg.get === "function") {
        const value = globalThis.ytcfg.get(name);
        if (value !== undefined) return value;
      }
      if (globalThis.ytcfg && globalThis.ytcfg.data_) {
        const value = globalThis.ytcfg.data_[name];
        if (value !== undefined) return value;
      }
    } catch (_) {}
    return null;
  };
  const context = get("INNERTUBE_CONTEXT");
  const sessionIndex = get("SESSION_INDEX");
  const delegatedSessionId = get("DELEGATED_SESSION_ID");
  const dataSyncId = get("DATASYNC_ID");
  return {
    innertubeContext: context || null,
    sessionIndex: sessionIndex == null ? null : String(sessionIndex),
    delegatedSessionId: delegatedSessionId == null ? null : String(delegatedSessionId),
    dataSyncId: dataSyncId == null ? null : String(dataSyncId),
    userAgent: navigator.userAgent || null
  };
})()
"#;

#[derive(Clone, Serialize, Deserialize)]
pub struct AuthConfig {
    pub schema: u32,
    pub source: AuthSource,
    pub headers: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub innertube_context: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthSource {
    pub kind: String,
    pub browser: Option<String>,
}

impl AuthConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let content = fs::read_to_string(path).map_err(|error| {
            HelperError::auth_required(format!(
                "cannot read auth file `{}`: {error}",
                path.display()
            ))
        })?;
        let config: Self = serde_json::from_str(&content).map_err(|error| {
            HelperError::auth_required(format!("invalid auth file `{}`: {error}", path.display()))
        })?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema != 1 {
            return Err(HelperError::auth_required(format!(
                "unsupported auth schema {}",
                self.schema
            )));
        }
        if self.source.kind != "login-window" {
            return Err(HelperError::auth_required(
                "unsupported auth source; rerun ytm-radio or use auth login-window".to_string(),
            ));
        }
        let cookie = self
            .header("cookie")
            .ok_or_else(|| HelperError::auth_required("auth file is missing the cookie header"))?;
        if cookie_value(cookie, "__Secure-3PAPISID")
            .or_else(|| cookie_value(cookie, "SAPISID"))
            .is_none()
        {
            return Err(HelperError::auth_required(
                "auth cookie is missing __Secure-3PAPISID or SAPISID; log in to YouTube Music"
                    .to_string(),
            ));
        }
        Ok(())
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    pub fn cookie(&self, name: &str) -> Option<&str> {
        self.header("cookie")
            .and_then(|header| cookie_value(header, name))
    }
}

pub fn login_window(
    output: &Path,
    browser: Option<&str>,
    profile_dir: Option<&Path>,
    port: u16,
    timeout: Duration,
    restart_running: bool,
    proxy: Option<&str>,
) -> Result<AuthConfig> {
    let browser = resolve_login_browser(browser)?;
    let profile_dir = effective_login_profile_dir(output, &browser, profile_dir);
    match browser.protocol() {
        LoginProtocol::Cdp => login_window_cdp(
            output,
            &browser,
            profile_dir.as_deref(),
            port,
            timeout,
            restart_running,
            proxy,
        ),
        LoginProtocol::Bidi => login_window_bidi(
            output,
            &browser,
            profile_dir.as_deref(),
            port,
            timeout,
            restart_running,
            proxy,
        ),
    }
}

fn effective_login_profile_dir(
    output: &Path,
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
) -> Option<PathBuf> {
    profile_dir
        .map(Path::to_path_buf)
        .or_else(|| automatic_login_profile_dir(output, browser))
}

fn automatic_login_profile_dir(output: &Path, browser: &LoginBrowser) -> Option<PathBuf> {
    if browser.kind == BrowserKind::Chrome {
        Some(output.with_file_name("login-profile"))
    } else {
        None
    }
}

fn login_window_cdp(
    output: &Path,
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
    port: u16,
    timeout: Duration,
    restart_running: bool,
    proxy: Option<&str>,
) -> Result<AuthConfig> {
    let client = Client::builder()
        .timeout(Duration::from_millis(900))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let base_url = cdp_base_url(port);
    let mut launched_child = None;
    let mut close_browser_when_done = false;
    let version = match cdp_version(&client, &base_url) {
        Ok(version) => version,
        Err(_) => {
            if login_browser_is_running(browser) {
                if restart_running {
                    restart_running_login_browser(browser)?;
                } else if let Some(error) =
                    running_login_browser_conflict(browser, port, profile_dir.is_some())
                {
                    return Err(error);
                }
            }
            launched_child = Some(spawn_login_browser(browser, profile_dir, port, proxy)?);
            close_browser_when_done = profile_dir.is_some();
            let Some(version) = wait_for_cdp_version(&client, &base_url, Duration::from_secs(8))
            else {
                if close_browser_when_done {
                    terminate_spawned_browser(&mut launched_child);
                }
                return Err(HelperError::network(format!(
                    "cannot reach login browser DevTools on 127.0.0.1:{port}; \
                     if the browser is already running, close it and run login again, \
                     or set ytm-radio-helper-login-profile-directory for an isolated login profile"
                )));
            };
            version
        }
    };
    let result = (|| {
        let target = open_music_login_target(&client, &base_url)?;
        let config = wait_for_login_config(&target, &version, browser.name(), timeout)?;
        write_private_json(output, &config)?;
        Ok(config)
    })();
    if close_browser_when_done {
        close_cdp_browser(version.browser_websocket_url.as_deref());
        terminate_spawned_browser(&mut launched_child);
    }
    result
}

fn login_window_bidi(
    output: &Path,
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
    port: u16,
    timeout: Duration,
    restart_running: bool,
    proxy: Option<&str>,
) -> Result<AuthConfig> {
    let client = Client::builder()
        .timeout(Duration::from_millis(900))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let mut launched_child = None;
    let mut close_browser_when_done = false;
    let mut connection = match connect_bidi(&client, port) {
        Ok(connection) => connection,
        Err(_) => {
            if login_browser_is_running(browser) {
                if restart_running {
                    restart_running_login_browser(browser)?;
                } else if let Some(error) =
                    running_login_browser_conflict(browser, port, profile_dir.is_some())
                {
                    return Err(error);
                }
            }
            launched_child = Some(spawn_login_browser(browser, profile_dir, port, proxy)?);
            close_browser_when_done = profile_dir.is_some();
            let Some(connection) = wait_for_bidi_connection(&client, port, Duration::from_secs(8))
            else {
                if close_browser_when_done {
                    terminate_spawned_browser(&mut launched_child);
                }
                return Err(HelperError::network(format!(
                    "cannot reach login browser WebDriver BiDi endpoint on 127.0.0.1:{port}; \
                     if the browser is already running, close it and run login again, \
                     or set ytm-radio-helper-login-profile-directory for an isolated login profile"
                )));
            };
            connection
        }
    };
    let result = (|| {
        let context = open_music_bidi_context(&mut connection)?;
        let config =
            wait_for_bidi_login_config(&mut connection, &context, browser.name(), timeout)?;
        write_private_json(output, &config)?;
        Ok(config)
    })();
    if close_browser_when_done {
        close_bidi_browser(&mut connection);
        terminate_spawned_browser(&mut launched_child);
    }
    result
}

fn restart_running_login_browser(browser: &LoginBrowser) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let bundle_id = macos_app_bundle_for_executable(&browser.executable)
            .and_then(|app_path| macos_bundle_identifier(&app_path))
            .ok_or_else(|| {
                format!(
                    "cannot determine app identity for `{}`; close it and run login again",
                    browser.executable.display()
                )
            })?;
        let quit_requested = macos_quit_app_id(&bundle_id)?;
        if !quit_requested {
            macos_terminate_browser_processes(browser)?;
        }
        match wait_for_login_browser_exit(browser, Duration::from_secs(8)) {
            Ok(()) => Ok(()),
            Err(error) if quit_requested => {
                macos_terminate_browser_processes(browser)?;
                wait_for_login_browser_exit(browser, Duration::from_secs(4)).map_err(|_| error)
            }
            Err(error) => Err(error),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = browser;
        Err("automatic browser restart is only implemented on macOS; close the browser and run login again"
            .into())
    }
}

#[cfg(target_os = "macos")]
fn macos_quit_app_id(bundle_id: &str) -> Result<bool> {
    let script = format!(
        "tell application id \"{}\" to quit",
        bundle_id.replace('\\', "\\\\").replace('"', "\\\"")
    );
    let output = Command::new("osascript")
        .args(["-e", &script])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot ask browser to quit: {error}"))?;
    if output.status.success() {
        return Ok(true);
    }
    let detail = String::from_utf8_lossy(&output.stderr)
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no diagnostic from osascript")
        .trim()
        .to_string();
    if detail.contains("User canceled") || detail.contains("(-128)") {
        return Ok(false);
    }
    Err(format!("cannot ask browser to quit: {detail}").into())
}

#[cfg(target_os = "macos")]
fn macos_terminate_browser_processes(browser: &LoginBrowser) -> Result<()> {
    let executable = browser.executable.to_string_lossy();
    let output = Command::new("ps")
        .args(["-axo", "pid=,command="])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot inspect browser processes: {error}"))?;
    if !output.status.success() {
        return Err("cannot inspect browser processes".into());
    }
    let pids = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| macos_process_line_for_executable(line, &executable))
        .filter(|pid| pid != &std::process::id().to_string())
        .collect::<Vec<_>>();
    if pids.is_empty() {
        return Err(format!(
            "browser `{}` did not quit and no matching process could be found",
            browser.executable.display()
        )
        .into());
    }
    for pid in pids {
        let status = Command::new("kill")
            .args(["-TERM", &pid])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|error| format!("cannot terminate browser process {pid}: {error}"))?;
        if !status.success() {
            return Err(format!("cannot terminate browser process {pid}").into());
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn macos_process_line_for_executable(line: &str, executable: &str) -> Option<String> {
    let line = line.trim_start();
    let (pid, command) = line.split_once(char::is_whitespace)?;
    if pid.chars().all(|character| character.is_ascii_digit()) && command.contains(executable) {
        Some(pid.to_string())
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
fn wait_for_login_browser_exit(browser: &LoginBrowser, timeout: Duration) -> Result<()> {
    let started = SystemTime::now();
    while login_browser_is_running(browser) {
        if started.elapsed().unwrap_or_default() >= timeout {
            return Err(format!(
                "browser `{}` did not quit; close it and run login again",
                browser.executable.display()
            )
            .into());
        }
        sleep(Duration::from_millis(200));
    }
    Ok(())
}

fn running_login_browser_conflict(
    browser: &LoginBrowser,
    port: u16,
    isolated_profile: bool,
) -> Option<HelperError> {
    if !login_browser_is_running(browser) {
        return None;
    }
    if isolated_profile && browser.kind != BrowserKind::Dia {
        return None;
    }
    if browser.kind == BrowserKind::Dia {
        return Some(HelperError::browser_restart_required(format!(
            "Dia is already running without {} on 127.0.0.1:{port}; \
             close Dia and run login again. Dia only permits one instance, \
             so ytm-radio will not start a second Dia process.",
            browser.protocol().endpoint_name()
        )));
    }
    Some(HelperError::browser_restart_required(format!(
        "login browser `{}` is already running without {} on 127.0.0.1:{port}; \
         close it and run login again, or set ytm-radio-helper-login-profile-directory \
         for an isolated login profile.",
        browser.executable.display(),
        browser.protocol().endpoint_name()
    )))
}

#[cfg(target_os = "macos")]
fn login_browser_is_running(browser: &LoginBrowser) -> bool {
    macos_app_bundle_for_executable(&browser.executable)
        .and_then(|app_path| macos_bundle_identifier(&app_path))
        .is_some_and(|bundle_id| macos_app_id_is_running(&bundle_id))
}

#[cfg(target_os = "linux")]
fn login_browser_is_running(browser: &LoginBrowser) -> bool {
    let Some(process_name) = browser
        .executable
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    Command::new("pgrep")
        .args(["-x", process_name])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(target_os = "windows")]
fn login_browser_is_running(browser: &LoginBrowser) -> bool {
    windows_login_browser_process_names(browser)
        .into_iter()
        .any(|process_name| windows_process_is_running(&process_name))
}

#[cfg(target_os = "windows")]
fn windows_login_browser_process_names(browser: &LoginBrowser) -> Vec<String> {
    let mut names = match browser.kind {
        BrowserKind::Chrome => vec!["chrome.exe".to_string()],
        BrowserKind::Brave => vec!["brave.exe".to_string()],
        BrowserKind::Edge => vec!["msedge.exe".to_string()],
        BrowserKind::Chromium => vec!["chromium.exe".to_string(), "chrome.exe".to_string()],
        BrowserKind::Firefox => vec!["firefox.exe".to_string()],
        BrowserKind::Zen => vec!["zen.exe".to_string()],
        BrowserKind::Dia => vec!["dia.exe".to_string()],
        BrowserKind::Custom(_) => Vec::new(),
    };
    if let Some(file_name) = browser
        .executable
        .file_name()
        .and_then(|name| name.to_str())
    {
        let process_name = if file_name.contains('.') {
            file_name.to_string()
        } else {
            format!("{file_name}.exe")
        };
        names.push(process_name);
    }
    dedup_strings(names)
}

#[cfg(target_os = "windows")]
fn windows_process_is_running(process_name: &str) -> bool {
    let output = Command::new("tasklist")
        .args(["/FO", "CSV", "/NH", "/FI"])
        .arg(format!("IMAGENAME eq {process_name}"))
        .stdin(Stdio::null())
        .output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let needle = format!("\"{}\"", process_name.to_ascii_lowercase());
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.to_ascii_lowercase().starts_with(&needle))
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn login_browser_is_running(_browser: &LoginBrowser) -> bool {
    false
}

fn auth_from_cdp_cookies_with_error(
    source_kind: &str,
    browser: Option<&str>,
    cookies: &[CdpCookie],
    user_agent: &str,
    missing_error: &str,
) -> Result<AuthConfig> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock error: {error}"))?
        .as_secs_f64();
    let mut cookie_map = BTreeMap::new();
    for cookie in cookies {
        if !is_youtube_domain(&cookie.domain) {
            continue;
        }
        if cookie.expires > 0.0 && cookie.expires <= now {
            continue;
        }
        cookie_map.insert(cookie.name.clone(), cookie.value.clone());
    }
    auth_from_cookie_map(source_kind, browser, cookie_map, user_agent, missing_error)
}

fn auth_from_bidi_cookies_with_error(
    source_kind: &str,
    browser: Option<&str>,
    cookies: Vec<BidiCookie>,
    user_agent: &str,
    missing_error: &str,
) -> Result<AuthConfig> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock error: {error}"))?
        .as_secs_f64();
    let mut cookie_map = BTreeMap::new();
    for cookie in cookies {
        if !is_youtube_domain(&cookie.domain) {
            continue;
        }
        if cookie.expiry.unwrap_or(0.0) > 0.0 && cookie.expiry.unwrap_or(0.0) <= now {
            continue;
        }
        cookie_map.insert(cookie.name, cookie.value.into_cookie_value()?);
    }
    auth_from_cookie_map(source_kind, browser, cookie_map, user_agent, missing_error)
}

fn auth_from_cookie_map(
    source_kind: &str,
    browser: Option<&str>,
    cookies: BTreeMap<String, String>,
    user_agent: &str,
    missing_error: &str,
) -> Result<AuthConfig> {
    if !cookies.contains_key("__Secure-3PAPISID") && !cookies.contains_key("SAPISID") {
        return Err(HelperError::auth_required(missing_error));
    }

    let cookie_header = cookies
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("; ");
    Ok(AuthConfig {
        schema: 1,
        source: AuthSource {
            kind: source_kind.to_string(),
            browser: browser.map(str::to_string),
        },
        headers: BTreeMap::from([
            ("cookie".to_string(), cookie_header),
            ("origin".to_string(), YTM_ORIGIN.to_string()),
            ("user-agent".to_string(), user_agent.to_string()),
            ("x-goog-authuser".to_string(), "0".to_string()),
        ]),
        innertube_context: None,
    })
}

#[derive(Debug, Deserialize)]
struct CdpVersion {
    #[serde(rename = "webSocketDebuggerUrl")]
    browser_websocket_url: Option<String>,
    #[serde(rename = "User-Agent")]
    user_agent: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CdpTarget {
    #[serde(default)]
    id: String,
    #[serde(rename = "webSocketDebuggerUrl")]
    websocket_url: String,
}

#[derive(Debug, Deserialize)]
struct CdpCookie {
    name: String,
    value: String,
    domain: String,
    #[serde(default)]
    expires: f64,
}

#[derive(Debug, Deserialize)]
struct BidiCookie {
    name: String,
    value: BidiBytesValue,
    domain: String,
    #[serde(default)]
    expiry: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum BidiBytesValue {
    #[serde(rename = "string")]
    String { value: String },
    #[serde(rename = "base64")]
    Base64 {
        #[serde(rename = "value")]
        _value: String,
    },
}

impl BidiBytesValue {
    fn into_cookie_value(self) -> Result<String> {
        match self {
            Self::String { value } => Ok(value),
            Self::Base64 { .. } => {
                Err("Firefox BiDi returned a base64 cookie value; text cookies are required".into())
            }
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq)]
struct BrowserSession {
    innertube_context: Option<Value>,
    session_index: Option<String>,
    delegated_session_id: Option<String>,
    data_sync_id: Option<String>,
    user_agent: Option<String>,
}

impl BrowserSession {
    fn has_identity(&self) -> bool {
        self.session_index.is_some()
            || self.delegated_session_id.is_some()
            || self.data_sync_id.is_some()
            || self
                .innertube_context
                .as_ref()
                .and_then(context_page_id)
                .is_some()
    }

    fn require_identity(self) -> Result<Self> {
        if self.has_identity() {
            Ok(self)
        } else {
            Err(HelperError::auth_required(
                "login window session identity is not ready; wait for music.youtube.com to finish loading"
                    .to_string(),
            ))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LoginProtocol {
    Cdp,
    Bidi,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum BrowserKind {
    Chrome,
    Brave,
    Edge,
    Chromium,
    Firefox,
    Zen,
    Dia,
    Custom(String),
}

impl BrowserKind {
    fn name(&self) -> &str {
        match self {
            Self::Chrome => "chrome",
            Self::Brave => "brave",
            Self::Edge => "edge",
            Self::Chromium => "chromium",
            Self::Firefox => "firefox",
            Self::Zen => "zen",
            Self::Dia => "dia",
            Self::Custom(name) => name,
        }
    }

    fn protocol(&self) -> LoginProtocol {
        match self {
            Self::Firefox | Self::Zen => LoginProtocol::Bidi,
            _ => LoginProtocol::Cdp,
        }
    }
}

impl LoginProtocol {
    fn endpoint_name(self) -> &'static str {
        match self {
            Self::Cdp => "DevTools",
            Self::Bidi => "WebDriver BiDi",
        }
    }
}

type BrowserSocket = WebSocket<MaybeTlsStream<TcpStream>>;

struct BidiConnection {
    socket: BrowserSocket,
    next_id: u64,
    user_agent: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LoginBrowser {
    kind: BrowserKind,
    executable: PathBuf,
}

impl LoginBrowser {
    fn name(&self) -> &str {
        self.kind.name()
    }

    fn protocol(&self) -> LoginProtocol {
        self.kind.protocol()
    }
}

fn cdp_base_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}

fn cdp_version(client: &Client, base_url: &str) -> Result<CdpVersion> {
    client
        .get(format!("{base_url}/json/version"))
        .send()
        .map_err(|error| {
            HelperError::network(format!("cannot connect to DevTools endpoint: {error}"))
        })?
        .error_for_status()
        .map_err(|error| {
            HelperError::helper_failure(format!(
                "DevTools endpoint rejected version request: {error}"
            ))
        })?
        .json()
        .map_err(|error| {
            HelperError::helper_failure(format!("invalid DevTools version response: {error}"))
        })
}

fn wait_for_cdp_version(client: &Client, base_url: &str, timeout: Duration) -> Option<CdpVersion> {
    let started = SystemTime::now();
    loop {
        if let Ok(version) = cdp_version(client, base_url) {
            return Some(version);
        }
        if started.elapsed().ok()? >= timeout {
            return None;
        }
        sleep(Duration::from_millis(150));
    }
}

fn resolve_login_browser(requested: Option<&str>) -> Result<LoginBrowser> {
    if let Some(requested) = requested.map(str::trim).filter(|value| !value.is_empty()) {
        if requested.eq_ignore_ascii_case("default") {
            return resolve_default_login_browser();
        }
        if requested.contains('/') || requested.contains('\\') {
            let executable = PathBuf::from(requested);
            if executable.exists() {
                let kind = supported_login_browser(&executable).unwrap_or_else(|| {
                    BrowserKind::Custom(
                        executable
                            .file_stem()
                            .and_then(|name| name.to_str())
                            .unwrap_or("custom")
                            .to_string(),
                    )
                });
                return Ok(LoginBrowser { kind, executable });
            }
            return Err(format!("cannot find login browser executable `{requested}`").into());
        }
        let requested_lower = requested.to_ascii_lowercase();
        if let Some(browser) = login_browser_candidates().into_iter().find(|candidate| {
            candidate.name() == requested_lower && login_browser_is_available(candidate)
        }) {
            return Ok(browser);
        }
        return Err(format!(
            "cannot find login browser `{requested}`; try {LOGIN_BROWSER_CHOICES}"
        )
        .into());
    }

    resolve_default_login_browser()
}

fn resolve_default_login_browser() -> Result<LoginBrowser> {
    let browser = default_login_browser()?;
    if login_browser_is_available(&browser) {
        return Ok(browser);
    }
    Err(format!(
        "default login browser `{}` is not available; set ytm-radio-helper-login-browser to {LOGIN_BROWSER_CHOICES}",
        browser.executable.display()
    )
    .into())
}

#[cfg(target_os = "macos")]
fn default_login_browser() -> Result<LoginBrowser> {
    let app_path = command_stdout(
        "osascript",
        &[
            "-e",
            "use framework \"AppKit\"",
            "-e",
            "set theURL to current application's NSURL's URLWithString:\"https://music.youtube.com\"",
            "-e",
            "set appURL to current application's NSWorkspace's sharedWorkspace()'s URLForApplicationToOpenURL:theURL",
            "-e",
            "if appURL is missing value then error \"no default browser\"",
            "-e",
            "return appURL's path() as string",
        ],
    )
    .ok_or_else(|| {
        "cannot determine the macOS default browser; set ytm-radio-helper-login-browser"
            .to_string()
    })?;
    let app_path = PathBuf::from(app_path);
    let executable = macos_app_executable(&app_path).unwrap_or(app_path);
    supported_default_login_browser(executable)
}

#[cfg(target_os = "macos")]
fn macos_app_executable(app_path: &Path) -> Option<PathBuf> {
    if app_path
        .extension()
        .and_then(|extension| extension.to_str())
        != Some("app")
    {
        return None;
    }
    let executable = command_stdout(
        "plutil",
        &[
            "-extract",
            "CFBundleExecutable",
            "raw",
            "-o",
            "-",
            app_path.join("Contents/Info.plist").to_str()?,
        ],
    )?;
    Some(app_path.join("Contents/MacOS").join(executable))
}

#[cfg(target_os = "macos")]
fn macos_app_bundle_for_executable(executable: &Path) -> Option<PathBuf> {
    executable
        .ancestors()
        .find(|ancestor| {
            ancestor
                .extension()
                .and_then(|extension| extension.to_str())
                == Some("app")
        })
        .map(Path::to_path_buf)
}

#[cfg(target_os = "macos")]
fn macos_bundle_identifier(app_path: &Path) -> Option<String> {
    command_stdout(
        "plutil",
        &[
            "-extract",
            "CFBundleIdentifier",
            "raw",
            "-o",
            "-",
            app_path.join("Contents/Info.plist").to_str()?,
        ],
    )
}

#[cfg(target_os = "macos")]
fn macos_app_id_is_running(bundle_id: &str) -> bool {
    let script = format!(
        "application id \"{}\" is running",
        bundle_id.replace('\\', "\\\\").replace('"', "\\\"")
    );
    command_stdout("osascript", &["-e", &script])
        .as_deref()
        .is_some_and(|output| output == "true")
}

#[cfg(target_os = "linux")]
fn default_login_browser() -> Result<LoginBrowser> {
    let desktop_id = command_stdout("xdg-settings", &["get", "default-web-browser"])
        .or_else(|| command_stdout("xdg-mime", &["query", "default", "x-scheme-handler/https"]))
        .ok_or_else(|| {
            "cannot determine the Linux default browser; set ytm-radio-helper-login-browser"
                .to_string()
        })?;
    let desktop_path = find_desktop_entry(&desktop_id)
        .ok_or_else(|| format!("cannot find default browser desktop entry `{desktop_id}`"))?;
    let content = fs::read_to_string(&desktop_path).map_err(|error| {
        format!(
            "cannot read default browser desktop entry `{}`: {error}",
            desktop_path.display()
        )
    })?;
    let exec = desktop_entry_exec(&content).ok_or_else(|| {
        format!(
            "default browser desktop entry `{}` has no Exec line",
            desktop_path.display()
        )
    })?;
    let executable = desktop_exec_command(exec).ok_or_else(|| {
        format!(
            "cannot parse Exec line from default browser desktop entry `{}`",
            desktop_path.display()
        )
    })?;
    supported_default_login_browser(PathBuf::from(executable))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn default_login_browser() -> Result<LoginBrowser> {
    Err(
        "cannot determine the default browser on this platform; set ytm-radio-helper-login-browser"
            .into(),
    )
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn command_stdout(program: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn supported_default_login_browser(executable: PathBuf) -> Result<LoginBrowser> {
    let Some(kind) = supported_login_browser(&executable) else {
        return Err(format!(
            "default browser `{}` is not supported for login; set ytm-radio-helper-login-browser to {LOGIN_BROWSER_CHOICES}",
            executable.display()
        )
        .into());
    };
    Ok(login_browser_path(kind, executable))
}

fn supported_login_browser(executable: &Path) -> Option<BrowserKind> {
    let path = executable.to_string_lossy().to_ascii_lowercase();
    let file_name = executable
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let file = executable
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if path.contains("google chrome")
        || matches!(
            file.as_str(),
            "google-chrome" | "google-chrome-stable" | "chrome"
        )
    {
        Some(BrowserKind::Chrome)
    } else if path.contains("brave browser") || file == "brave-browser" || file == "brave" {
        Some(BrowserKind::Brave)
    } else if path.contains("microsoft edge")
        || matches!(file.as_str(), "microsoft-edge" | "msedge")
    {
        Some(BrowserKind::Edge)
    } else if path.contains("chromium") || matches!(file.as_str(), "chromium" | "chromium-browser")
    {
        Some(BrowserKind::Chromium)
    } else if path.contains("firefox") || file == "firefox" {
        Some(BrowserKind::Firefox)
    } else if matches!(file.as_str(), "zen" | "zen-browser")
        || (file_name.ends_with(".appimage") && file.starts_with("zen-"))
    {
        Some(BrowserKind::Zen)
    } else if path.contains("/dia.app/") || file == "dia" {
        Some(BrowserKind::Dia)
    } else {
        None
    }
}

#[cfg(target_os = "linux")]
fn find_desktop_entry(desktop_id: &str) -> Option<PathBuf> {
    let direct = PathBuf::from(desktop_id);
    if direct.exists() {
        return Some(direct);
    }
    desktop_application_dirs()
        .into_iter()
        .map(|directory| directory.join(desktop_id))
        .find(|path| path.exists())
}

#[cfg(target_os = "linux")]
fn desktop_application_dirs() -> Vec<PathBuf> {
    let mut directories = Vec::new();
    if let Some(xdg_data_home) = std::env::var_os("XDG_DATA_HOME") {
        directories.push(PathBuf::from(xdg_data_home).join("applications"));
    } else if let Some(home) = std::env::var_os("HOME") {
        directories.push(PathBuf::from(home).join(".local/share/applications"));
    }
    let xdg_data_dirs = std::env::var_os("XDG_DATA_DIRS")
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".to_string());
    directories.extend(
        xdg_data_dirs
            .split(':')
            .filter(|directory| !directory.is_empty())
            .map(|directory| PathBuf::from(directory).join("applications")),
    );
    directories
}

#[cfg(target_os = "linux")]
fn desktop_entry_exec(content: &str) -> Option<&str> {
    let mut in_desktop_entry = false;
    for line in content.lines().map(str::trim) {
        if line.starts_with('[') && line.ends_with(']') {
            in_desktop_entry = line == "[Desktop Entry]";
            continue;
        }
        if in_desktop_entry {
            if let Some(exec) = line.strip_prefix("Exec=") {
                return Some(exec.trim());
            }
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn desktop_exec_command(exec: &str) -> Option<String> {
    let tokens = split_desktop_exec(exec);
    let mut index = 0;
    if tokens.get(index).is_some_and(|token| token == "env") {
        index += 1;
        while let Some(token) = tokens.get(index) {
            if token.starts_with('-') {
                index += 1;
                continue;
            }
            if token.contains('=') {
                index += 1;
                continue;
            }
            break;
        }
    }
    tokens
        .get(index)
        .filter(|token| !token.contains('%'))
        .cloned()
}

#[cfg(target_os = "linux")]
fn split_desktop_exec(exec: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut token = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for character in exec.chars() {
        if escaped {
            token.push(character);
            escaped = false;
            continue;
        }
        match character {
            '\\' => escaped = true,
            '"' => quoted = !quoted,
            character if character.is_whitespace() && !quoted => {
                if !token.is_empty() {
                    tokens.push(std::mem::take(&mut token));
                }
            }
            _ => token.push(character),
        }
    }
    if !token.is_empty() {
        tokens.push(token);
    }
    tokens
}

fn login_browser_candidates() -> Vec<LoginBrowser> {
    let mut candidates = Vec::new();
    #[cfg(target_os = "macos")]
    {
        candidates.extend([
            login_browser(
                BrowserKind::Chrome,
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            ),
            login_browser(
                BrowserKind::Brave,
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            ),
            login_browser(
                BrowserKind::Edge,
                "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            ),
            login_browser(
                BrowserKind::Chromium,
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
            ),
            login_browser(
                BrowserKind::Firefox,
                "/Applications/Firefox.app/Contents/MacOS/firefox",
            ),
            login_browser(BrowserKind::Zen, "/Applications/Zen.app/Contents/MacOS/zen"),
            login_browser(BrowserKind::Dia, DEFAULT_DIA_LOGIN_BROWSER_PATH),
        ]);
        if let Some(home) = std::env::var_os("HOME") {
            let home = PathBuf::from(home);
            candidates.extend([
                login_browser_path(
                    BrowserKind::Chrome,
                    home.join("Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
                ),
                login_browser_path(
                    BrowserKind::Brave,
                    home.join("Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
                ),
                login_browser_path(
                    BrowserKind::Edge,
                    home.join("Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
                ),
                login_browser_path(
                    BrowserKind::Chromium,
                    home.join("Applications/Chromium.app/Contents/MacOS/Chromium"),
                ),
                login_browser_path(
                    BrowserKind::Firefox,
                    home.join("Applications/Firefox.app/Contents/MacOS/firefox"),
                ),
                login_browser_path(
                    BrowserKind::Zen,
                    home.join("Applications/Zen.app/Contents/MacOS/zen"),
                ),
            ]);
        }
    }
    #[cfg(target_os = "linux")]
    {
        candidates.extend([
            login_browser(BrowserKind::Chrome, "google-chrome"),
            login_browser(BrowserKind::Chrome, "google-chrome-stable"),
            login_browser(BrowserKind::Brave, "brave-browser"),
            login_browser(BrowserKind::Edge, "microsoft-edge"),
            login_browser(BrowserKind::Chromium, "chromium"),
            login_browser(BrowserKind::Chromium, "chromium-browser"),
            login_browser(BrowserKind::Firefox, "firefox"),
            login_browser(BrowserKind::Firefox, "firefox-developer-edition"),
            login_browser(BrowserKind::Zen, "zen"),
            login_browser(BrowserKind::Zen, "zen-browser"),
        ]);
    }
    #[cfg(target_os = "windows")]
    {
        candidates.extend(windows_login_browser_candidates());
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        candidates.extend([
            login_browser(BrowserKind::Chrome, "google-chrome"),
            login_browser(BrowserKind::Chrome, "chrome"),
            login_browser(BrowserKind::Brave, "brave"),
            login_browser(BrowserKind::Edge, "msedge"),
            login_browser(BrowserKind::Chromium, "chromium"),
            login_browser(BrowserKind::Firefox, "firefox"),
            login_browser(BrowserKind::Zen, "zen"),
        ]);
    }
    candidates
}

#[cfg(target_os = "windows")]
fn windows_login_browser_candidates() -> Vec<LoginBrowser> {
    let mut candidates = vec![
        login_browser(BrowserKind::Chrome, "chrome.exe"),
        login_browser(BrowserKind::Brave, "brave.exe"),
        login_browser(BrowserKind::Edge, "msedge.exe"),
        login_browser(BrowserKind::Chromium, "chromium.exe"),
        login_browser(BrowserKind::Firefox, "firefox.exe"),
        login_browser(BrowserKind::Zen, "zen.exe"),
    ];
    for root in windows_program_roots() {
        candidates.extend([
            login_browser_path(
                BrowserKind::Chrome,
                root.join("Google")
                    .join("Chrome")
                    .join("Application")
                    .join("chrome.exe"),
            ),
            login_browser_path(
                BrowserKind::Brave,
                root.join("BraveSoftware")
                    .join("Brave-Browser")
                    .join("Application")
                    .join("brave.exe"),
            ),
            login_browser_path(
                BrowserKind::Edge,
                root.join("Microsoft")
                    .join("Edge")
                    .join("Application")
                    .join("msedge.exe"),
            ),
            login_browser_path(
                BrowserKind::Firefox,
                root.join("Mozilla Firefox").join("firefox.exe"),
            ),
            login_browser_path(BrowserKind::Zen, root.join("Zen Browser").join("zen.exe")),
            login_browser_path(BrowserKind::Zen, root.join("Zen").join("zen.exe")),
        ]);
    }
    if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
        let root = PathBuf::from(local_app_data);
        candidates.extend([
            login_browser_path(
                BrowserKind::Chrome,
                root.join("Google")
                    .join("Chrome")
                    .join("Application")
                    .join("chrome.exe"),
            ),
            login_browser_path(
                BrowserKind::Brave,
                root.join("BraveSoftware")
                    .join("Brave-Browser")
                    .join("Application")
                    .join("brave.exe"),
            ),
            login_browser_path(
                BrowserKind::Edge,
                root.join("Microsoft")
                    .join("Edge")
                    .join("Application")
                    .join("msedge.exe"),
            ),
            login_browser_path(
                BrowserKind::Zen,
                root.join("Programs").join("Zen Browser").join("zen.exe"),
            ),
            login_browser_path(
                BrowserKind::Zen,
                root.join("Programs").join("Zen").join("zen.exe"),
            ),
        ]);
    }
    candidates
}

#[cfg(target_os = "windows")]
fn windows_program_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(value) = std::env::var_os(variable) {
            roots.push(PathBuf::from(value));
        }
    }
    dedup_paths(roots)
}

#[cfg(target_os = "windows")]
fn dedup_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut deduped = Vec::new();
    for path in paths {
        if !deduped.iter().any(|known| known == &path) {
            deduped.push(path);
        }
    }
    deduped
}

fn login_browser(kind: BrowserKind, executable: &str) -> LoginBrowser {
    login_browser_path(kind, PathBuf::from(executable))
}

fn login_browser_path(kind: BrowserKind, executable: PathBuf) -> LoginBrowser {
    LoginBrowser { kind, executable }
}

fn login_browser_is_available(browser: &LoginBrowser) -> bool {
    if browser.executable.components().count() > 1 || browser.executable.is_absolute() {
        return browser.executable.exists();
    }
    Command::new(&browser.executable)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

fn spawn_login_browser(
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
    port: u16,
    proxy: Option<&str>,
) -> Result<Child> {
    match browser.protocol() {
        LoginProtocol::Cdp => spawn_cdp_login_browser(browser, profile_dir, port, proxy),
        LoginProtocol::Bidi => spawn_bidi_login_browser(browser, profile_dir, port),
    }
}

fn cdp_login_browser_arguments(
    profile_dir: Option<&Path>,
    port: u16,
    proxy: Option<&str>,
) -> Vec<String> {
    let mut arguments = vec![
        format!("--remote-debugging-port={port}"),
        "--remote-debugging-address=127.0.0.1".to_string(),
    ];
    if let Some(proxy) = proxy {
        arguments.push(format!("--proxy-server={proxy}"));
    }
    if let Some(profile_dir) = profile_dir {
        arguments.push(format!("--user-data-dir={}", profile_dir.display()));
    }
    arguments.push("--no-first-run".to_string());
    arguments.push("--new-window".to_string());
    arguments
}

fn spawn_cdp_login_browser(
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
    port: u16,
    proxy: Option<&str>,
) -> Result<Child> {
    let mut command = Command::new(&browser.executable);
    if let Some(profile_dir) = profile_dir {
        fs::create_dir_all(profile_dir).map_err(|error| {
            format!(
                "cannot create login browser profile `{}`: {error}",
                profile_dir.display()
            )
        })?;
    }
    command.args(cdp_login_browser_arguments(profile_dir, port, proxy));
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            HelperError::helper_failure(format!(
                "cannot start login browser `{}`: {error}",
                browser.executable.display()
            ))
        })
}

fn spawn_bidi_login_browser(
    browser: &LoginBrowser,
    profile_dir: Option<&Path>,
    port: u16,
) -> Result<Child> {
    let mut command = Command::new(&browser.executable);
    if let Some(profile_dir) = profile_dir {
        fs::create_dir_all(profile_dir).map_err(|error| {
            format!(
                "cannot create login browser profile `{}`: {error}",
                profile_dir.display()
            )
        })?;
    }
    command
        .args(bidi_login_browser_arguments(profile_dir, port))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            HelperError::helper_failure(format!(
                "cannot start login browser `{}`: {error}",
                browser.executable.display()
            ))
        })
}

fn bidi_login_browser_arguments(profile_dir: Option<&Path>, port: u16) -> Vec<String> {
    let mut arguments = vec![format!("--remote-debugging-port={port}")];
    if let Some(profile_dir) = profile_dir {
        arguments.push("--profile".to_string());
        arguments.push(profile_dir.display().to_string());
        arguments.push("--no-remote".to_string());
    }
    arguments.push("--new-window".to_string());
    arguments.push("about:blank".to_string());
    arguments
}

fn wait_for_login_config(
    target: &CdpTarget,
    version: &CdpVersion,
    browser_name: &str,
    timeout: Duration,
) -> Result<AuthConfig> {
    let started = SystemTime::now();
    let mut last_error: Option<HelperError> = None;
    loop {
        if started.elapsed().unwrap_or_default() >= timeout {
            return Err(last_error.unwrap_or_else(|| {
                HelperError::auth_required(
                    "login window did not expose an authenticated YouTube Music session before timeout",
                )
            }));
        }
        match login_config_once(target, version, browser_name) {
            Ok(config) => return Ok(config),
            Err(error) => last_error = Some(error),
        }
        sleep(Duration::from_secs(1));
    }
}

fn login_config_once(
    target: &CdpTarget,
    version: &CdpVersion,
    browser_name: &str,
) -> Result<AuthConfig> {
    let session = cdp_session(&target.websocket_url)?.require_identity()?;
    let cookies = cdp_cookies(&target.websocket_url)?;
    let mut config = auth_from_cdp_cookies_with_error(
        "login-window",
        Some(browser_name),
        &cookies,
        version.user_agent.as_deref().unwrap_or(DEFAULT_USER_AGENT),
        "login window is not authenticated yet; finish signing in to music.youtube.com",
    )?;
    apply_browser_session(&mut config, session);
    Ok(config)
}

fn open_music_login_target(client: &Client, base_url: &str) -> Result<CdpTarget> {
    let target: CdpTarget = client
        .put(format!("{base_url}/json/new?{YTM_ORIGIN_ENCODED}"))
        .send()
        .map_err(|error| format!("cannot open YouTube Music in DevTools browser: {error}"))?
        .error_for_status()
        .map_err(|error| format!("DevTools rejected new tab request: {error}"))?
        .json()
        .map_err(|error| format!("invalid DevTools new tab response: {error}"))?;
    if target.websocket_url.is_empty() {
        return Err("DevTools target did not include a websocket URL".into());
    }
    activate_cdp_target(client, base_url, &target);
    Ok(target)
}

fn activate_cdp_target(client: &Client, base_url: &str, target: &CdpTarget) {
    if target.id.is_empty() {
        return;
    }
    let _ = client
        .get(format!("{base_url}/json/activate/{}", target.id))
        .send()
        .and_then(|response| response.error_for_status());
}

fn cdp_cookies(websocket_url: &str) -> Result<Vec<CdpCookie>> {
    let response = cdp_call(websocket_url, 1, "Network.getAllCookies")?;
    let cookies = response
        .pointer("/result/cookies")
        .cloned()
        .ok_or_else(|| "DevTools cookie response did not include cookies".to_string())?;
    serde_json::from_value(cookies).map_err(|error| {
        HelperError::helper_failure(format!("invalid DevTools cookie response: {error}"))
    })
}

fn cdp_session(websocket_url: &str) -> Result<BrowserSession> {
    let response = cdp_call_with_params(
        websocket_url,
        2,
        "Runtime.evaluate",
        json!({
            "expression": YTM_SESSION_EXPRESSION,
            "returnByValue": true,
            "awaitPromise": true
        }),
    )?;
    if let Some(exception) = response.get("exceptionDetails") {
        return Err(format!(
            "DevTools failed to evaluate YouTube Music session context: {exception}"
        )
        .into());
    }
    let value = response
        .pointer("/result/result/value")
        .ok_or_else(|| "DevTools session context response did not include a value".to_string())?;
    Ok(BrowserSession {
        innertube_context: value
            .get("innertubeContext")
            .filter(|context| context.is_object())
            .cloned(),
        session_index: json_string_field(value, "sessionIndex"),
        delegated_session_id: json_string_field(value, "delegatedSessionId"),
        data_sync_id: json_string_field(value, "dataSyncId"),
        user_agent: json_string_field(value, "userAgent"),
    })
}

fn json_string_field(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(str::to_string)
}

fn apply_browser_session(config: &mut AuthConfig, mut session: BrowserSession) {
    if let Some(session_index) = session.session_index.take() {
        config
            .headers
            .insert("x-goog-authuser".to_string(), session_index);
    }

    let page_id = session
        .delegated_session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| session.innertube_context.as_ref().and_then(context_page_id))
        .or_else(|| session.data_sync_id.as_deref().and_then(data_sync_page_id));
    if let Some(page_id) = page_id {
        config
            .headers
            .insert("x-goog-pageid".to_string(), page_id.clone());
        if let Some(context) = session.innertube_context.as_mut() {
            insert_on_behalf_of_user(context, &page_id);
        }
    }

    if let Some(context) = session.innertube_context.take() {
        config.innertube_context = Some(context);
    }
}

fn context_page_id(context: &Value) -> Option<String> {
    context
        .pointer("/user/onBehalfOfUser")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn data_sync_page_id(data_sync_id: &str) -> Option<String> {
    let first = data_sync_id
        .split("||")
        .next()
        .unwrap_or(data_sync_id)
        .trim();
    (!first.is_empty()
        && first.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '-'
        }))
    .then(|| first.to_string())
}

fn insert_on_behalf_of_user(context: &mut Value, page_id: &str) {
    let Some(context_object) = context.as_object_mut() else {
        return;
    };
    if !context_object
        .get("user")
        .map(Value::is_object)
        .unwrap_or(false)
    {
        context_object.insert("user".to_string(), Value::Object(serde_json::Map::new()));
    }
    if let Some(user) = context_object
        .get_mut("user")
        .and_then(Value::as_object_mut)
    {
        user.entry("onBehalfOfUser".to_string())
            .or_insert_with(|| Value::String(page_id.to_string()));
    }
}

fn cdp_call(websocket_url: &str, id: u64, method: &str) -> Result<Value> {
    cdp_call_with_params(websocket_url, id, method, Value::Null)
}

fn cdp_call_with_params(
    websocket_url: &str,
    id: u64,
    method: &str,
    params: Value,
) -> Result<Value> {
    let (mut socket, _) = connect(websocket_url)
        .map_err(|error| format!("cannot connect to DevTools websocket: {error}"))?;
    let mut payload = json!({ "id": id, "method": method });
    if !params.is_null() {
        payload
            .as_object_mut()
            .expect("payload is an object")
            .insert("params".to_string(), params);
    }
    socket
        .send(Message::Text(payload.to_string()))
        .map_err(|error| format!("cannot send DevTools request: {error}"))?;
    loop {
        let message = socket
            .read()
            .map_err(|error| format!("cannot read DevTools response: {error}"))?;
        let Ok(text) = message.into_text() else {
            continue;
        };
        let response: Value = serde_json::from_str(&text)
            .map_err(|error| format!("invalid DevTools websocket response: {error}"))?;
        if response.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        if let Some(error) = response.get("error") {
            return Err(format!("DevTools `{method}` failed: {error}").into());
        }
        return Ok(response);
    }
}

fn close_cdp_browser(websocket_url: Option<&str>) {
    if let Some(websocket_url) = websocket_url {
        let _ = cdp_call(websocket_url, 99, "Browser.close");
    }
}

fn wait_for_bidi_connection(
    client: &Client,
    port: u16,
    timeout: Duration,
) -> Option<BidiConnection> {
    let started = SystemTime::now();
    loop {
        if let Ok(connection) = connect_bidi(client, port) {
            return Some(connection);
        }
        if started.elapsed().ok()? >= timeout {
            return None;
        }
        sleep(Duration::from_millis(150));
    }
}

fn connect_bidi(client: &Client, port: u16) -> Result<BidiConnection> {
    let mut last_error: Option<HelperError> = None;
    for url in bidi_websocket_urls(client, port) {
        match BidiConnection::connect(&url).and_then(|mut connection| {
            connection.start_session()?;
            Ok(connection)
        }) {
            Ok(connection) => return Ok(connection),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        HelperError::network(format!(
            "cannot find WebDriver BiDi websocket URL on 127.0.0.1:{port}"
        ))
    }))
}

fn bidi_websocket_urls(client: &Client, port: u16) -> Vec<String> {
    let mut urls = Vec::new();
    if let Some(url) = browser_websocket_url(client, port) {
        urls.push(url);
    }
    urls.push(format!("ws://127.0.0.1:{port}/session"));
    urls.push(format!("ws://127.0.0.1:{port}"));
    dedup_strings(urls)
}

fn browser_websocket_url(client: &Client, port: u16) -> Option<String> {
    client
        .get(format!("{}/json/version", cdp_base_url(port)))
        .send()
        .ok()?
        .json::<CdpVersion>()
        .ok()?
        .browser_websocket_url
}

fn dedup_strings(values: Vec<String>) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        if !result.contains(&value) {
            result.push(value);
        }
    }
    result
}

impl BidiConnection {
    fn connect(url: &str) -> Result<Self> {
        let (socket, _) = connect(url).map_err(|error| {
            HelperError::network(format!(
                "cannot connect to WebDriver BiDi websocket `{url}`: {error}"
            ))
        })?;
        Ok(Self {
            socket,
            next_id: 1,
            user_agent: None,
        })
    }

    fn start_session(&mut self) -> Result<()> {
        self.call("session.status", json!({}))?;
        let result = self.call(
            "session.new",
            json!({
                "capabilities": {}
            }),
        )?;
        self.user_agent = result
            .pointer("/capabilities/userAgent")
            .and_then(Value::as_str)
            .map(str::to_string);
        Ok(())
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let payload = json!({
            "id": id,
            "method": method,
            "params": params
        });
        self.socket
            .send(Message::Text(payload.to_string()))
            .map_err(|error| format!("cannot send WebDriver BiDi request: {error}"))?;
        loop {
            let message = self
                .socket
                .read()
                .map_err(|error| format!("cannot read WebDriver BiDi response: {error}"))?;
            let Ok(text) = message.into_text() else {
                continue;
            };
            let response: Value = serde_json::from_str(&text)
                .map_err(|error| format!("invalid WebDriver BiDi websocket response: {error}"))?;
            if response.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            match response.get("type").and_then(Value::as_str) {
                Some("success") => {
                    return Ok(response.get("result").cloned().unwrap_or_else(|| json!({})));
                }
                Some("error") => {
                    let error = response
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown error");
                    let message = response
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("no message");
                    return Err(
                        format!("WebDriver BiDi `{method}` failed: {error}: {message}").into(),
                    );
                }
                _ => {
                    return Err(format!(
                        "WebDriver BiDi `{method}` returned an invalid response: {response}"
                    )
                    .into());
                }
            }
        }
    }
}

fn open_music_bidi_context(connection: &mut BidiConnection) -> Result<String> {
    let result = connection.call("browsingContext.create", json!({ "type": "tab" }))?;
    let context = result
        .get("context")
        .and_then(Value::as_str)
        .ok_or_else(|| "WebDriver BiDi did not return a browsing context".to_string())?
        .to_string();
    connection.call(
        "browsingContext.navigate",
        json!({
            "context": context,
            "url": YTM_ORIGIN,
            "wait": "interactive"
        }),
    )?;
    let _ = connection.call("browsingContext.activate", json!({ "context": context }));
    Ok(context)
}

fn wait_for_bidi_login_config(
    connection: &mut BidiConnection,
    context: &str,
    browser_name: &str,
    timeout: Duration,
) -> Result<AuthConfig> {
    let started = SystemTime::now();
    let mut last_error: Option<HelperError> = None;
    loop {
        if started.elapsed().unwrap_or_default() >= timeout {
            return Err(last_error.unwrap_or_else(|| {
                HelperError::auth_required(
                    "login window did not expose an authenticated YouTube Music session before timeout",
                )
            }));
        }
        match bidi_login_config_once(connection, context, browser_name) {
            Ok(config) => return Ok(config),
            Err(error) => last_error = Some(error),
        }
        sleep(Duration::from_secs(1));
    }
}

fn bidi_login_config_once(
    connection: &mut BidiConnection,
    context: &str,
    browser_name: &str,
) -> Result<AuthConfig> {
    let session = bidi_session(connection, context)?.require_identity()?;
    let user_agent = session
        .user_agent
        .as_deref()
        .or(connection.user_agent.as_deref())
        .unwrap_or(DEFAULT_USER_AGENT)
        .to_string();
    let cookies = bidi_cookies(connection, context)?;
    let mut config = auth_from_bidi_cookies_with_error(
        "login-window",
        Some(browser_name),
        cookies,
        &user_agent,
        "login window is not authenticated yet; finish signing in to music.youtube.com",
    )?;
    apply_browser_session(&mut config, session);
    Ok(config)
}

fn bidi_cookies(connection: &mut BidiConnection, context: &str) -> Result<Vec<BidiCookie>> {
    let result = connection
        .call(
            "storage.getCookies",
            json!({
                "partition": {
                    "type": "context",
                    "context": context
                }
            }),
        )
        .or_else(|_| connection.call("storage.getCookies", json!({})))?;
    let cookies = result
        .get("cookies")
        .cloned()
        .ok_or_else(|| "WebDriver BiDi cookie response did not include cookies".to_string())?;
    serde_json::from_value(cookies).map_err(|error| {
        HelperError::helper_failure(format!("invalid WebDriver BiDi cookie response: {error}"))
    })
}

fn bidi_session(connection: &mut BidiConnection, context: &str) -> Result<BrowserSession> {
    let expression = format!("JSON.stringify({YTM_SESSION_EXPRESSION})");
    let result = connection.call(
        "script.evaluate",
        json!({
            "expression": expression,
            "target": {
                "context": context
            },
            "awaitPromise": true,
            "userActivation": false
        }),
    )?;
    if result.get("type").and_then(Value::as_str) == Some("exception") {
        return Err(format!(
            "WebDriver BiDi failed to evaluate YouTube Music session context: {result}"
        )
        .into());
    }
    let text = result
        .pointer("/result/value")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            "WebDriver BiDi session context response did not include a JSON value".to_string()
        })?;
    let value: Value = serde_json::from_str(text)
        .map_err(|error| format!("invalid WebDriver BiDi session context: {error}"))?;
    Ok(BrowserSession {
        innertube_context: value
            .get("innertubeContext")
            .filter(|context| context.is_object())
            .cloned(),
        session_index: json_string_field(&value, "sessionIndex"),
        delegated_session_id: json_string_field(&value, "delegatedSessionId"),
        data_sync_id: json_string_field(&value, "dataSyncId"),
        user_agent: json_string_field(&value, "userAgent"),
    })
}

fn close_bidi_browser(connection: &mut BidiConnection) {
    if connection.call("browser.close", json!({})).is_err() {
        let _ = connection.call("session.end", json!({}));
    }
}

fn terminate_spawned_browser(child: &mut Option<Child>) {
    if let Some(child) = child.as_mut() {
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
        }
    }
}

fn is_youtube_domain(domain: &str) -> bool {
    let domain = domain.trim_start_matches('.');
    domain == "youtube.com" || domain.ends_with(".youtube.com")
}

fn write_private_json(path: &Path, config: &AuthConfig) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create `{}`: {error}", parent.display()))?;
    }
    let content = serde_json::to_vec_pretty(config)
        .map_err(|error| format!("cannot encode auth file: {error}"))?;
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, content)
        .map_err(|error| format!("cannot write `{}`: {error}", temporary.display()))?;
    set_private_permissions(&temporary)?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("cannot install `{}`: {error}", path.display()))?;
    Ok(())
}

#[cfg(unix)]
fn set_private_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        HelperError::helper_failure(format!("cannot protect `{}`: {error}", path.display()))
    })
}

#[cfg(not(unix))]
fn set_private_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

fn cookie_value<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').find_map(|part| {
        let (key, value) = part.trim().split_once('=')?;
        (key == name).then_some(value)
    })
}

#[cfg(test)]
#[path = "auth/tests.rs"]
mod tests;
