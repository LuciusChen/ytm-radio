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
pub const DEFAULT_DIA_APP_PATH: &str = "/Applications/Dia.app/Contents/MacOS/Dia";
const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthConfig {
    pub schema: u32,
    pub source: AuthSource,
    pub headers: BTreeMap<String, String>,
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

pub fn import_browser(browser: &str, output: &Path, yt_dlp: &str) -> Result<AuthConfig, String> {
    reject_unsupported_browser_import(browser)?;

    let cookie_file = temporary_cookie_path();
    let command_output = Command::new(yt_dlp)
        .args([
            "--ignore-config",
            "--cookies-from-browser",
            browser,
            "--cookies",
        ])
        .arg(&cookie_file)
        .args([
            "--skip-download",
            "--simulate",
            "--no-warnings",
            "https://music.youtube.com/",
        ])
        .output()
        .map_err(|error| format!("cannot run `{yt_dlp}`: {error}"))?;

    if !command_output.status.success() {
        let _ = fs::remove_file(&cookie_file);
        return Err(format!(
            "yt-dlp cookie export failed: {}",
            command_error_detail(&command_output.stderr)
        ));
    }
    if !cookie_file.exists() {
        return Err(format!(
            "yt-dlp did not export a cookie file: {}",
            command_error_detail(&command_output.stderr)
        ));
    }

    let parsed = fs::read_to_string(&cookie_file)
        .map_err(|error| format!("cannot read exported browser cookies: {error}"))
        .and_then(|content| auth_from_netscape(browser, &content));
    let _ = fs::remove_file(&cookie_file);
    let config = parsed.map_err(|error| {
        let detail = String::from_utf8_lossy(&command_output.stderr);
        let detail = detail
            .lines()
            .last()
            .unwrap_or("yt-dlp cookie export failed");
        format!("{error}: {detail}")
    })?;
    write_private_json(output, &config)?;
    Ok(config)
}

pub fn import_headers(input: &Path, output: &Path) -> Result<AuthConfig, String> {
    let content = fs::read_to_string(input)
        .map_err(|error| format!("cannot read headers file `{}`: {error}", input.display()))?;
    let config = auth_from_headers(&content)?;
    write_private_json(output, &config)?;
    Ok(config)
}

pub fn import_dia(
    output: &Path,
    port: u16,
    app: &Path,
    restart: bool,
) -> Result<AuthConfig, String> {
    let client = Client::builder()
        .timeout(Duration::from_millis(900))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let base_url = cdp_base_url(port);
    let mut launched_child = None;
    let mut launched_debug = false;
    let mut restore_normal_dia = false;
    let version = match cdp_version(&client, &base_url) {
        Ok(version) => version,
        Err(_) => {
            if restart {
                quit_dia_for_restart()?;
                restore_normal_dia = true;
            }
            launched_child = Some(spawn_dia_with_cdp(app, port)?);
            launched_debug = true;
            let Some(version) = wait_for_cdp_version(&client, &base_url, Duration::from_secs(6))
            else {
                terminate_spawned_dia(&mut launched_child);
                if restore_normal_dia {
                    reopen_dia_normally(app);
                }
                return Err(format!(
                    "cannot reach Dia remote debugging on 127.0.0.1:{port}; \
                     if Dia is already running, quit Dia and run import again"
                ));
            };
            version
        }
    };
    let result = (|| {
        let target = find_or_open_music_target(&client, &base_url)?;
        let cookies = cdp_cookies(&target.websocket_url)?;
        let config = auth_from_cdp_cookies(
            "dia-cdp",
            Some("dia"),
            &cookies,
            version.user_agent.as_deref().unwrap_or(DEFAULT_USER_AGENT),
        )?;
        write_private_json(output, &config)?;
        Ok(config)
    })();
    if launched_debug {
        close_cdp_browser(version.browser_websocket_url.as_deref());
        terminate_spawned_dia(&mut launched_child);
    }
    if restore_normal_dia {
        reopen_dia_normally(app);
    }
    result
}

fn auth_from_netscape(browser: &str, content: &str) -> Result<AuthConfig, String> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock error: {error}"))?
        .as_secs();
    let mut cookies = BTreeMap::new();
    for line in content.lines() {
        if line.is_empty() || (line.starts_with('#') && !line.starts_with("#HttpOnly_")) {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() != 7 {
            continue;
        }
        let domain = fields[0].trim_start_matches("#HttpOnly_");
        if !(domain == "youtube.com" || domain.ends_with(".youtube.com")) {
            continue;
        }
        let expires = fields[4].parse::<u64>().unwrap_or(0);
        if expires != 0 && expires <= now {
            continue;
        }
        cookies.insert(fields[5].to_string(), fields[6].to_string());
    }

    auth_from_cookie_map(
        "browser",
        Some(browser),
        cookies,
        DEFAULT_USER_AGENT,
        "exported cookies do not contain an authenticated YouTube session",
    )
}

fn auth_from_headers(content: &str) -> Result<AuthConfig, String> {
    let mut headers = BTreeMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(':') {
            continue;
        }
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if name.is_empty() || value.is_empty() {
            continue;
        }
        if header_name_is_supported(&name) {
            headers.insert(name, value.to_string());
        }
    }

    headers
        .entry("origin".to_string())
        .or_insert_with(|| YTM_ORIGIN.to_string());
    headers
        .entry("user-agent".to_string())
        .or_insert_with(|| DEFAULT_USER_AGENT.to_string());
    headers
        .entry("x-goog-authuser".to_string())
        .or_insert_with(|| "0".to_string());

    let config = AuthConfig {
        schema: 1,
        source: AuthSource {
            kind: "headers".to_string(),
            browser: None,
        },
        headers,
    };
    config.validate()?;
    Ok(config)
}

fn auth_from_cdp_cookies(
    source_kind: &str,
    browser: Option<&str>,
    cookies: &[CdpCookie],
    user_agent: &str,
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
    auth_from_cookie_map(
        source_kind,
        browser,
        cookie_map,
        user_agent,
        "Dia did not expose an authenticated YouTube Music session; log in to music.youtube.com first",
    )
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
    })
}

fn header_name_is_supported(name: &str) -> bool {
    matches!(name, "cookie" | "origin" | "user-agent" | "x-goog-authuser")
}

fn reject_unsupported_browser_import(browser: &str) -> Result<(), String> {
    let browser_name = browser
        .split([':', '+'])
        .next()
        .unwrap_or(browser)
        .trim()
        .to_ascii_lowercase();
    if browser_name == "dia" {
        return Err(
            "Dia cookie import is not supported by yt-dlp. Dia uses Chromium cookies, \
             but its cookie encryption is not exposed through a yt-dlp supported browser \
             profile. Use `auth import-dia --output FILE`, or import from Chrome, Firefox, \
             Safari, Edge, Brave, Chromium, Opera, Vivaldi, or Whale."
                .to_string(),
        );
    }
    Ok(())
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
    #[serde(rename = "type")]
    target_type: String,
    url: String,
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

fn spawn_dia_with_cdp(app: &Path, port: u16) -> Result<Child, String> {
    if !app.exists() {
        return Err(format!(
            "cannot find Dia executable `{}`; set the Dia app path explicitly",
            app.display()
        ));
    }
    Command::new(app)
        .arg(format!("--remote-debugging-port={port}"))
        .arg("--remote-debugging-address=127.0.0.1")
        .arg(YTM_ORIGIN)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot start Dia with remote debugging: {error}"))
}

#[cfg(target_os = "macos")]
fn quit_dia_for_restart() -> Result<(), String> {
    let output = Command::new("osascript")
        .args([
            "-e",
            "tell application id \"company.thebrowser.dia\" to quit",
        ])
        .output()
        .map_err(|error| format!("cannot ask Dia to quit: {error}"))?;
    if !output.status.success() {
        let detail = command_error_detail(&output.stderr);
        if wait_for_dia_exit(Duration::from_secs(3)) {
            return Ok(());
        }
        if detail.contains("User canceled") || detail.contains("(-128)") {
            return Err(
                "Dia quit was canceled; approve the Dia restart prompt or close Dia manually"
                    .to_string(),
            );
        }
        return Err(format!("cannot ask Dia to quit: {detail}"));
    }
    if wait_for_dia_exit(Duration::from_secs(8)) {
        return Ok(());
    }
    Err("Dia did not quit; close Dia and run import again".to_string())
}

#[cfg(target_os = "macos")]
fn wait_for_dia_exit(timeout: Duration) -> bool {
    let started = SystemTime::now();
    while dia_is_running() {
        if started.elapsed().unwrap_or_default() > timeout {
            return false;
        }
        sleep(Duration::from_millis(200));
    }
    true
}

#[cfg(not(target_os = "macos"))]
fn quit_dia_for_restart() -> Result<(), String> {
    Err("automatic Dia restart is only implemented on macOS".to_string())
}

#[cfg(target_os = "macos")]
fn dia_is_running() -> bool {
    Command::new("osascript")
        .args(["-e", "application id \"company.thebrowser.dia\" is running"])
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .is_some_and(|output| output.trim() == "true")
}

#[cfg(target_os = "macos")]
fn reopen_dia_normally(app: &Path) {
    let opened = Command::new("open")
        .args(["-b", "company.thebrowser.dia"])
        .spawn()
        .is_ok();
    if !opened {
        let _ = Command::new(app).spawn();
    }
}

#[cfg(not(target_os = "macos"))]
fn reopen_dia_normally(_app: &Path) {}

fn find_or_open_music_target(client: &Client, base_url: &str) -> Result<CdpTarget, String> {
    if let Some(target) = list_cdp_targets(client, base_url)?
        .into_iter()
        .find(|target| target.target_type == "page" && target.url.starts_with(YTM_ORIGIN))
    {
        return Ok(target);
    }
    let target: CdpTarget = client
        .put(format!("{base_url}/json/new?{YTM_ORIGIN_ENCODED}"))
        .send()
        .map_err(|error| format!("cannot open YouTube Music in Dia: {error}"))?
        .error_for_status()
        .map_err(|error| format!("DevTools rejected new tab request: {error}"))?
        .json()
        .map_err(|error| format!("invalid DevTools new tab response: {error}"))?;
    if target.websocket_url.is_empty() {
        return Err("DevTools target did not include a websocket URL".to_string());
    }
    Ok(target)
}

fn list_cdp_targets(client: &Client, base_url: &str) -> Result<Vec<CdpTarget>, String> {
    client
        .get(format!("{base_url}/json/list"))
        .send()
        .map_err(|error| format!("cannot list Dia DevTools targets: {error}"))?
        .error_for_status()
        .map_err(|error| format!("DevTools rejected target list request: {error}"))?
        .json()
        .map_err(|error| format!("invalid DevTools target list: {error}"))
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

fn cdp_call(websocket_url: &str, id: u64, method: &str) -> Result<Value, String> {
    let (mut socket, _) = connect(websocket_url)
        .map_err(|error| format!("cannot connect to DevTools websocket: {error}"))?;
    socket
        .send(Message::Text(
            json!({ "id": id, "method": method }).to_string(),
        ))
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

fn terminate_spawned_dia(child: &mut Option<Child>) {
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

fn command_error_detail(stderr: &[u8]) -> String {
    let detail = String::from_utf8_lossy(stderr);
    detail
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no diagnostic from yt-dlp")
        .trim()
        .to_string()
}

fn temporary_cookie_path() -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    std::env::temp_dir().join(format!(
        "ytm-radio-cookies-{}-{stamp}.txt",
        std::process::id()
    ))
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
    fn parses_authenticated_netscape_cookie_file() {
        let input = concat!(
            "# Netscape HTTP Cookie File\n",
            ".youtube.com\tTRUE\t/\tTRUE\t4102444800\t__Secure-3PAPISID\tsecret\n",
            ".youtube.com\tTRUE\t/\tTRUE\t4102444800\tSID\tsid-value\n",
            ".example.com\tTRUE\t/\tTRUE\t4102444800\tignored\tvalue\n"
        );
        let config = auth_from_netscape("chrome:Default", input).unwrap();
        assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
        assert!(!config.header("cookie").unwrap().contains("ignored"));
    }

    #[test]
    fn rejects_cookie_file_without_youtube_login() {
        let error = auth_from_netscape("chrome", "# Netscape HTTP Cookie File\n").unwrap_err();
        assert!(error.contains("authenticated YouTube session"));
    }

    #[test]
    fn parses_browser_request_headers() {
        let input = concat!(
            ":method: POST\n",
            "User-Agent: Browser UA\n",
            "Cookie: SID=sid-value; __Secure-3PAPISID=secret\n",
            "X-Goog-AuthUser: 1\n",
            "Accept-Language: en-US\n"
        );
        let config = auth_from_headers(input).unwrap();
        assert_eq!(config.source.kind, "headers");
        assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
        assert_eq!(config.header("user-agent"), Some("Browser UA"));
        assert_eq!(config.header("x-goog-authuser"), Some("1"));
        assert!(config.header("accept-language").is_none());
    }

    #[test]
    fn rejects_headers_without_authenticated_cookie() {
        let error = auth_from_headers("User-Agent: Browser UA\n").unwrap_err();
        assert!(error.contains("missing the cookie header"));
    }

    #[test]
    fn builds_auth_from_cdp_cookies() {
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
        let config = auth_from_cdp_cookies("dia-cdp", Some("dia"), &cookies, "Dia UA").unwrap();
        assert_eq!(config.source.kind, "dia-cdp");
        assert_eq!(config.source.browser, Some("dia".to_string()));
        assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
        assert_eq!(config.header("user-agent"), Some("Dia UA"));
        assert!(!config.header("cookie").unwrap().contains("ignored"));
        assert!(!config.header("cookie").unwrap().contains("expired"));
    }

    #[test]
    fn rejects_dia_browser_cookie_import_with_actionable_error() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let auth_file = directory.join("auth.json");
        let error = import_browser("dia", &auth_file, "yt-dlp").unwrap_err();
        assert!(error.contains("Dia cookie import is not supported"));
        assert!(error.contains("auth import-dia"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn imports_header_file_through_public_boundary() {
        use std::os::unix::fs::MetadataExt;

        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let headers_file = directory.join("headers.txt");
        let auth_file = directory.join("auth.json");
        fs::write(
            &headers_file,
            "Cookie: SAPISID=secret\nUser-Agent: Browser UA\n",
        )
        .unwrap();

        let config = import_headers(&headers_file, &auth_file).unwrap();
        assert_eq!(config.cookie("SAPISID"), Some("secret"));
        assert_eq!(fs::metadata(&auth_file).unwrap().mode() & 0o777, 0o600);
        assert!(AuthConfig::load(&auth_file).is_ok());
        fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn imports_browser_cookies_through_yt_dlp_boundary() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let fake_yt_dlp = directory.join("yt-dlp");
        let auth_file = directory.join("auth.json");
        fs::write(
            &fake_yt_dlp,
            concat!(
                "#!/bin/sh\n",
                "while [ \"$1\" != \"--cookies\" ]; do shift; done\n",
                "shift\n",
                "printf '# Netscape HTTP Cookie File\\n.youtube.com\\tTRUE\\t/\\tTRUE\\t4102444800\\t__Secure-3PAPISID\\tsecret\\n' > \"$1\"\n",
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_yt_dlp, fs::Permissions::from_mode(0o700)).unwrap();

        let config =
            import_browser("chrome:Default", &auth_file, fake_yt_dlp.to_str().unwrap()).unwrap();
        assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
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
