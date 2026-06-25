use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tungstenite::{connect, Message};

const YTM_ORIGIN: &str = "https://music.youtube.com";
const YTM_ORIGIN_ENCODED: &str = "https%3A%2F%2Fmusic.youtube.com";
const DEFAULT_DIA_LOGIN_BROWSER_PATH: &str = "/Applications/Dia.app/Contents/MacOS/Dia";
const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

#[derive(Debug, Clone, Serialize, Deserialize)]
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
    pub fn load(path: &Path) -> Result<Self, String> {
        let content = fs::read_to_string(path)
            .map_err(|error| format!("cannot read auth file `{}`: {error}", path.display()))?;
        let config: Self = serde_json::from_str(&content)
            .map_err(|error| format!("invalid auth file `{}`: {error}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema != 1 {
            return Err(format!("unsupported auth schema {}", self.schema));
        }
        if self.source.kind != "login-window" {
            return Err(
                "unsupported auth source; rerun ytm-radio or use auth login-window".to_string(),
            );
        }
        let cookie = self
            .header("cookie")
            .ok_or_else(|| "auth file is missing the cookie header".to_string())?;
        if cookie_value(cookie, "__Secure-3PAPISID")
            .or_else(|| cookie_value(cookie, "SAPISID"))
            .is_none()
        {
            return Err(
                "auth cookie is missing __Secure-3PAPISID or SAPISID; log in to YouTube Music"
                    .to_string(),
            );
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
) -> Result<AuthConfig, String> {
    let browser = resolve_login_browser(browser)?;
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
            if login_browser_is_running(&browser) {
                if restart_running {
                    restart_running_login_browser(&browser)?;
                } else if let Some(error) =
                    running_login_browser_conflict(&browser, port, profile_dir.is_some())
                {
                    return Err(error);
                }
            }
            launched_child = Some(spawn_login_browser(&browser, profile_dir, port)?);
            close_browser_when_done = profile_dir.is_some();
            let Some(version) = wait_for_cdp_version(&client, &base_url, Duration::from_secs(8))
            else {
                if close_browser_when_done {
                    terminate_spawned_browser(&mut launched_child);
                }
                return Err(format!(
                    "cannot reach login browser DevTools on 127.0.0.1:{port}; \
                     if the browser is already running, close it and run login again, \
                     or set ytm-radio-helper-login-profile-directory for an isolated login profile"
                ));
            };
            version
        }
    };
    let result = (|| {
        let target = open_music_login_target(&client, &base_url)?;
        let config = wait_for_login_config(&target, &version, browser.name.as_str(), timeout)?;
        write_private_json(output, &config)?;
        Ok(config)
    })();
    if close_browser_when_done {
        close_cdp_browser(version.browser_websocket_url.as_deref());
        terminate_spawned_browser(&mut launched_child);
    }
    result
}

fn restart_running_login_browser(browser: &LoginBrowser) -> Result<(), String> {
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
            .to_string())
    }
}

#[cfg(target_os = "macos")]
fn macos_quit_app_id(bundle_id: &str) -> Result<bool, String> {
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
    Err(format!("cannot ask browser to quit: {detail}"))
}

#[cfg(target_os = "macos")]
fn macos_terminate_browser_processes(browser: &LoginBrowser) -> Result<(), String> {
    let executable = browser.executable.to_string_lossy();
    let output = Command::new("ps")
        .args(["-axo", "pid=,command="])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot inspect browser processes: {error}"))?;
    if !output.status.success() {
        return Err("cannot inspect browser processes".to_string());
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
        ));
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
            return Err(format!("cannot terminate browser process {pid}"));
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
fn wait_for_login_browser_exit(browser: &LoginBrowser, timeout: Duration) -> Result<(), String> {
    let started = SystemTime::now();
    while login_browser_is_running(browser) {
        if started.elapsed().unwrap_or_default() >= timeout {
            return Err(format!(
                "browser `{}` did not quit; close it and run login again",
                browser.executable.display()
            ));
        }
        sleep(Duration::from_millis(200));
    }
    Ok(())
}

fn running_login_browser_conflict(
    browser: &LoginBrowser,
    port: u16,
    isolated_profile: bool,
) -> Option<String> {
    if !login_browser_is_running(browser) {
        return None;
    }
    if isolated_profile && browser.name != "dia" {
        return None;
    }
    if browser.name == "dia" {
        return Some(format!(
            "Dia is already running without DevTools on 127.0.0.1:{port}; \
             close Dia and run login again. Dia only permits one instance, \
             so ytm-radio will not start a second Dia process."
        ));
    }
    Some(format!(
        "login browser `{}` is already running without DevTools on 127.0.0.1:{port}; \
         close it and run login again, or set ytm-radio-helper-login-profile-directory \
         for an isolated login profile.",
        browser.executable.display()
    ))
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

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn login_browser_is_running(_browser: &LoginBrowser) -> bool {
    false
}

fn auth_from_cdp_cookies_with_error(
    source_kind: &str,
    browser: Option<&str>,
    cookies: &[CdpCookie],
    user_agent: &str,
    missing_error: &str,
) -> Result<AuthConfig, String> {
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

fn auth_from_cookie_map(
    source_kind: &str,
    browser: Option<&str>,
    cookies: BTreeMap<String, String>,
    user_agent: &str,
    missing_error: &str,
) -> Result<AuthConfig, String> {
    if !cookies.contains_key("__Secure-3PAPISID") && !cookies.contains_key("SAPISID") {
        return Err(missing_error.to_string());
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

#[derive(Debug, Default, Clone, PartialEq)]
struct BrowserSession {
    innertube_context: Option<Value>,
    session_index: Option<String>,
    delegated_session_id: Option<String>,
    data_sync_id: Option<String>,
}

impl BrowserSession {
    fn has_identity(&self) -> bool {
        self.innertube_context.is_some()
            || self.session_index.is_some()
            || self.delegated_session_id.is_some()
            || self.data_sync_id.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LoginBrowser {
    name: String,
    executable: PathBuf,
}

fn cdp_base_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}

fn cdp_version(client: &Client, base_url: &str) -> Result<CdpVersion, String> {
    client
        .get(format!("{base_url}/json/version"))
        .send()
        .map_err(|error| format!("cannot connect to DevTools endpoint: {error}"))?
        .error_for_status()
        .map_err(|error| format!("DevTools endpoint rejected version request: {error}"))?
        .json()
        .map_err(|error| format!("invalid DevTools version response: {error}"))
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

fn resolve_login_browser(requested: Option<&str>) -> Result<LoginBrowser, String> {
    if let Some(requested) = requested.map(str::trim).filter(|value| !value.is_empty()) {
        if requested.eq_ignore_ascii_case("default") {
            return resolve_default_login_browser();
        }
        if requested.contains('/') || requested.contains('\\') {
            let executable = PathBuf::from(requested);
            if executable.exists() {
                return Ok(LoginBrowser {
                    name: executable
                        .file_stem()
                        .and_then(|name| name.to_str())
                        .unwrap_or("custom")
                        .to_string(),
                    executable,
                });
            }
            return Err(format!(
                "cannot find login browser executable `{requested}`"
            ));
        }
        let requested_lower = requested.to_ascii_lowercase();
        if let Some(browser) = login_browser_candidates().into_iter().find(|candidate| {
            candidate.name == requested_lower && login_browser_is_available(candidate)
        }) {
            return Ok(browser);
        }
        return Err(format!(
            "cannot find login browser `{requested}`; try chrome, brave, edge, chromium, dia, or an executable path"
        ));
    }

    resolve_default_login_browser()
}

fn resolve_default_login_browser() -> Result<LoginBrowser, String> {
    let browser = default_login_browser()?;
    if login_browser_is_available(&browser) {
        return Ok(browser);
    }
    Err(format!(
        "default login browser `{}` is not available; set ytm-radio-helper-login-browser to chrome, brave, edge, chromium, dia, or an executable path",
        browser.executable.display()
    ))
}

#[cfg(target_os = "macos")]
fn default_login_browser() -> Result<LoginBrowser, String> {
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
fn default_login_browser() -> Result<LoginBrowser, String> {
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
fn default_login_browser() -> Result<LoginBrowser, String> {
    Err(
        "cannot determine the default browser on this platform; set ytm-radio-helper-login-browser"
            .to_string(),
    )
}

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

fn supported_default_login_browser(executable: PathBuf) -> Result<LoginBrowser, String> {
    let Some(name) = supported_login_browser_name(&executable) else {
        return Err(format!(
            "default browser `{}` is not supported for login; set ytm-radio-helper-login-browser to chrome, brave, edge, chromium, dia, or a Chromium-compatible executable path",
            executable.display()
        ));
    };
    Ok(login_browser_path(name, executable))
}

fn supported_login_browser_name(executable: &Path) -> Option<&'static str> {
    let path = executable.to_string_lossy().to_ascii_lowercase();
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
        Some("chrome")
    } else if path.contains("brave browser") || file == "brave-browser" || file == "brave" {
        Some("brave")
    } else if path.contains("microsoft edge") || file == "microsoft-edge" {
        Some("edge")
    } else if path.contains("chromium") || matches!(file.as_str(), "chromium" | "chromium-browser")
    {
        Some("chromium")
    } else if path.contains("/dia.app/") || file == "dia" {
        Some("dia")
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
                "chrome",
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            ),
            login_browser(
                "brave",
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            ),
            login_browser(
                "edge",
                "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            ),
            login_browser(
                "chromium",
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
            ),
            login_browser("dia", DEFAULT_DIA_LOGIN_BROWSER_PATH),
        ]);
        if let Some(home) = std::env::var_os("HOME") {
            let home = PathBuf::from(home);
            candidates.extend([
                login_browser_path(
                    "chrome",
                    home.join("Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
                ),
                login_browser_path(
                    "brave",
                    home.join("Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
                ),
                login_browser_path(
                    "edge",
                    home.join("Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
                ),
                login_browser_path(
                    "chromium",
                    home.join("Applications/Chromium.app/Contents/MacOS/Chromium"),
                ),
            ]);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        candidates.extend([
            login_browser("chrome", "google-chrome"),
            login_browser("chrome", "google-chrome-stable"),
            login_browser("brave", "brave-browser"),
            login_browser("edge", "microsoft-edge"),
            login_browser("chromium", "chromium"),
            login_browser("chromium", "chromium-browser"),
        ]);
    }
    candidates
}

fn login_browser(name: &str, executable: &str) -> LoginBrowser {
    login_browser_path(name, PathBuf::from(executable))
}

fn login_browser_path(name: &str, executable: PathBuf) -> LoginBrowser {
    LoginBrowser {
        name: name.to_string(),
        executable,
    }
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
) -> Result<Child, String> {
    let mut command = Command::new(&browser.executable);
    command
        .arg(format!("--remote-debugging-port={port}"))
        .arg("--remote-debugging-address=127.0.0.1");
    if let Some(profile_dir) = profile_dir {
        fs::create_dir_all(profile_dir).map_err(|error| {
            format!(
                "cannot create login browser profile `{}`: {error}",
                profile_dir.display()
            )
        })?;
        command.arg(format!("--user-data-dir={}", profile_dir.display()));
    }
    command
        .arg("--no-first-run")
        .arg("--new-window")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            format!(
                "cannot start login browser `{}`: {error}",
                browser.executable.display()
            )
        })
}

fn wait_for_login_config(
    target: &CdpTarget,
    version: &CdpVersion,
    browser_name: &str,
    timeout: Duration,
) -> Result<AuthConfig, String> {
    let started = SystemTime::now();
    let mut last_error = None;
    loop {
        if started.elapsed().unwrap_or_default() >= timeout {
            return Err(last_error.unwrap_or_else(|| {
                "login window did not expose an authenticated YouTube Music session before timeout"
                    .to_string()
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
) -> Result<AuthConfig, String> {
    let cookies = cdp_cookies(&target.websocket_url)?;
    let mut config = auth_from_cdp_cookies_with_error(
        "login-window",
        Some(browser_name),
        &cookies,
        version.user_agent.as_deref().unwrap_or(DEFAULT_USER_AGENT),
        "login window is not authenticated yet; finish signing in to music.youtube.com",
    )?;
    if let Ok(session) = cdp_session(&target.websocket_url) {
        if session.has_identity() {
            apply_browser_session(&mut config, session);
        }
    }
    Ok(config)
}

fn open_music_login_target(client: &Client, base_url: &str) -> Result<CdpTarget, String> {
    let target: CdpTarget = client
        .put(format!("{base_url}/json/new?{YTM_ORIGIN_ENCODED}"))
        .send()
        .map_err(|error| format!("cannot open YouTube Music in DevTools browser: {error}"))?
        .error_for_status()
        .map_err(|error| format!("DevTools rejected new tab request: {error}"))?
        .json()
        .map_err(|error| format!("invalid DevTools new tab response: {error}"))?;
    if target.websocket_url.is_empty() {
        return Err("DevTools target did not include a websocket URL".to_string());
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

fn cdp_cookies(websocket_url: &str) -> Result<Vec<CdpCookie>, String> {
    let response = cdp_call(websocket_url, 1, "Network.getAllCookies")?;
    let cookies = response
        .pointer("/result/cookies")
        .cloned()
        .ok_or_else(|| "DevTools cookie response did not include cookies".to_string())?;
    serde_json::from_value(cookies)
        .map_err(|error| format!("invalid DevTools cookie response: {error}"))
}

fn cdp_session(websocket_url: &str) -> Result<BrowserSession, String> {
    let expression = r#"
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
    dataSyncId: dataSyncId == null ? null : String(dataSyncId)
  };
})()
"#;
    let response = cdp_call_with_params(
        websocket_url,
        2,
        "Runtime.evaluate",
        json!({
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true
        }),
    )?;
    if let Some(exception) = response.get("exceptionDetails") {
        return Err(format!(
            "DevTools failed to evaluate YouTube Music session context: {exception}"
        ));
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

fn cdp_call(websocket_url: &str, id: u64, method: &str) -> Result<Value, String> {
    cdp_call_with_params(websocket_url, id, method, Value::Null)
}

fn cdp_call_with_params(
    websocket_url: &str,
    id: u64,
    method: &str,
    params: Value,
) -> Result<Value, String> {
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
            return Err(format!("DevTools `{method}` failed: {error}"));
        }
        return Ok(response);
    }
}

fn close_cdp_browser(websocket_url: Option<&str>) {
    if let Some(websocket_url) = websocket_url {
        let _ = cdp_call(websocket_url, 99, "Browser.close");
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

fn write_private_json(path: &Path, config: &AuthConfig) -> Result<(), String> {
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
fn set_private_permissions(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("cannot protect `{}`: {error}", path.display()))
}

#[cfg(not(unix))]
fn set_private_permissions(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn cookie_value<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').find_map(|part| {
        let (key, value) = part.trim().split_once('=')?;
        (key == name).then_some(value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_DIRECTORY_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn builds_login_auth_from_cdp_cookies() {
        let cookies = vec![
            CdpCookie {
                name: "__Secure-3PAPISID".to_string(),
                value: "secret".to_string(),
                domain: ".youtube.com".to_string(),
                expires: 0.0,
            },
            CdpCookie {
                name: "expired".to_string(),
                value: "old".to_string(),
                domain: ".youtube.com".to_string(),
                expires: 1.0,
            },
            CdpCookie {
                name: "ignored".to_string(),
                value: "value".to_string(),
                domain: ".example.com".to_string(),
                expires: 0.0,
            },
        ];
        let config = auth_from_cdp_cookies_with_error(
            "login-window",
            Some("chrome"),
            &cookies,
            "Browser UA",
            "missing login",
        )
        .unwrap();
        assert_eq!(config.source.kind, "login-window");
        assert_eq!(config.source.browser, Some("chrome".to_string()));
        assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
        assert_eq!(config.header("user-agent"), Some("Browser UA"));
        assert!(!config.header("cookie").unwrap().contains("ignored"));
        assert!(!config.header("cookie").unwrap().contains("expired"));
    }

    #[test]
    fn rejects_cdp_cookies_without_login() {
        let cookies = vec![CdpCookie {
            name: "SID".to_string(),
            value: "sid".to_string(),
            domain: ".youtube.com".to_string(),
            expires: 0.0,
        }];
        let error = auth_from_cdp_cookies_with_error(
            "login-window",
            Some("chrome"),
            &cookies,
            "Browser UA",
            "missing login",
        )
        .unwrap_err();
        assert_eq!(error, "missing login");
    }

    #[test]
    fn parses_cdp_target_id_for_activation() {
        let target: CdpTarget = serde_json::from_value(json!({
            "id": "target-1",
            "type": "page",
            "url": YTM_ORIGIN,
            "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/page/target-1"
        }))
        .unwrap();
        assert_eq!(target.id, "target-1");
        assert_eq!(
            target.websocket_url,
            "ws://127.0.0.1/devtools/page/target-1"
        );
    }

    #[test]
    fn rejects_old_auth_source_kinds() {
        let config: AuthConfig = serde_json::from_value(json!({
            "schema": 1,
            "source": {"kind": "browser", "browser": "chrome"},
            "headers": {
                "cookie": "__Secure-3PAPISID=secret",
                "origin": YTM_ORIGIN
            }
        }))
        .unwrap();
        let error = config.validate().unwrap_err();
        assert!(error.contains("auth login-window"));
    }

    #[test]
    fn applies_browser_session_identity_to_auth_config() {
        let cookies = vec![CdpCookie {
            name: "__Secure-3PAPISID".to_string(),
            value: "secret".to_string(),
            domain: ".youtube.com".to_string(),
            expires: 0.0,
        }];
        let mut config = auth_from_cdp_cookies_with_error(
            "login-window",
            Some("chrome"),
            &cookies,
            "Browser UA",
            "missing login",
        )
        .unwrap();
        apply_browser_session(
            &mut config,
            BrowserSession {
                innertube_context: Some(json!({
                    "client": {"clientName": "WEB_REMIX"},
                    "user": {}
                })),
                session_index: Some("2".to_string()),
                delegated_session_id: Some("brand-page-id".to_string()),
                data_sync_id: None,
            },
        );
        assert_eq!(config.header("x-goog-authuser"), Some("2"));
        assert_eq!(config.header("x-goog-pageid"), Some("brand-page-id"));
        assert_eq!(
            config
                .innertube_context
                .as_ref()
                .and_then(|context| context.pointer("/user/onBehalfOfUser"))
                .and_then(Value::as_str),
            Some("brand-page-id")
        );
    }

    #[test]
    fn resolves_login_browser_from_explicit_path() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let browser = directory.join("Test Browser");
        fs::write(&browser, "").unwrap();

        let resolved = resolve_login_browser(Some(browser.to_str().unwrap())).unwrap();

        assert_eq!(resolved.name, "Test Browser");
        assert_eq!(resolved.executable, browser);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn recognizes_supported_default_browser_paths() {
        assert_eq!(
            supported_login_browser_name(Path::new("/Applications/Dia.app/Contents/MacOS/Dia")),
            Some("dia")
        );
        assert_eq!(
            supported_login_browser_name(Path::new(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            )),
            Some("chrome")
        );
        assert_eq!(
            supported_login_browser_name(Path::new("/usr/bin/brave-browser")),
            Some("brave")
        );
        assert_eq!(
            supported_login_browser_name(Path::new("/usr/bin/firefox")),
            None
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parses_macos_browser_process_lines() {
        assert_eq!(
            macos_process_line_for_executable(
                " 1234 /Applications/Dia.app/Contents/MacOS/Dia --flag",
                "/Applications/Dia.app/Contents/MacOS/Dia"
            ),
            Some("1234".to_string())
        );
        assert_eq!(
            macos_process_line_for_executable(
                " 1234 /Applications/Other.app/Contents/MacOS/Other",
                "/Applications/Dia.app/Contents/MacOS/Dia"
            ),
            None
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn parses_linux_desktop_exec_command() {
        assert_eq!(
            desktop_exec_command(r#""/opt/google/chrome/google-chrome" %U"#),
            Some("/opt/google/chrome/google-chrome".to_string())
        );
        assert_eq!(
            desktop_exec_command("env FOO=bar brave-browser %U"),
            Some("brave-browser".to_string())
        );
        assert_eq!(desktop_exec_command("%U"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn reads_desktop_entry_exec_from_primary_section() {
        let content = concat!(
            "[Desktop Entry]\n",
            "Name=Browser\n",
            "Exec=chromium-browser %U\n",
            "\n",
            "[Desktop Action NewWindow]\n",
            "Exec=ignored\n"
        );
        assert_eq!(desktop_entry_exec(content), Some("chromium-browser %U"));
    }

    #[cfg(unix)]
    #[test]
    fn writes_private_login_auth_file() {
        use std::os::unix::fs::MetadataExt;

        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let auth_file = directory.join("auth.json");
        let config = AuthConfig {
            schema: 1,
            source: AuthSource {
                kind: "login-window".to_string(),
                browser: Some("chrome".to_string()),
            },
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=secret".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
            ]),
            innertube_context: None,
        };

        write_private_json(&auth_file, &config).unwrap();

        assert_eq!(fs::metadata(&auth_file).unwrap().mode() & 0o777, 0o600);
        assert!(AuthConfig::load(&auth_file).is_ok());
        fs::remove_dir_all(directory).unwrap();
    }

    fn temporary_test_directory() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let counter = TEST_DIRECTORY_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "ytm-radio-auth-test-{}-{stamp}-{counter}",
            std::process::id()
        ))
    }
}
