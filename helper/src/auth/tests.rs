// SPDX-License-Identifier: GPL-3.0-or-later

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
    .err()
    .expect("missing login must be rejected");
    assert_eq!(error.message, "missing login");
    assert_eq!(error.code, "auth-required");
}

#[test]
fn builds_login_auth_from_bidi_cookies() {
    let cookies = vec![
        BidiCookie {
            name: "__Secure-3PAPISID".to_string(),
            value: BidiBytesValue::String {
                value: "secret".to_string(),
            },
            domain: ".youtube.com".to_string(),
            expiry: None,
        },
        BidiCookie {
            name: "expired".to_string(),
            value: BidiBytesValue::String {
                value: "old".to_string(),
            },
            domain: ".youtube.com".to_string(),
            expiry: Some(1.0),
        },
        BidiCookie {
            name: "ignored".to_string(),
            value: BidiBytesValue::String {
                value: "value".to_string(),
            },
            domain: ".example.com".to_string(),
            expiry: None,
        },
    ];
    let config = auth_from_bidi_cookies_with_error(
        "login-window",
        Some("firefox"),
        cookies,
        "Firefox UA",
        "missing login",
    )
    .unwrap();
    assert_eq!(config.source.kind, "login-window");
    assert_eq!(config.source.browser, Some("firefox".to_string()));
    assert_eq!(config.cookie("__Secure-3PAPISID"), Some("secret"));
    assert_eq!(config.header("user-agent"), Some("Firefox UA"));
    assert!(!config.header("cookie").unwrap().contains("ignored"));
    assert!(!config.header("cookie").unwrap().contains("expired"));
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
    assert!(error.message.contains("auth login-window"));
    assert!(error.auth_required);
}

#[test]
fn waits_for_browser_session_identity_before_completing_login() {
    let error = BrowserSession::default().require_identity().unwrap_err();
    assert!(error.message.contains("session identity is not ready"));

    let context_only = BrowserSession {
        innertube_context: Some(json!({
            "client": {"clientName": "WEB_REMIX"},
            "user": {}
        })),
        ..BrowserSession::default()
    };
    assert!(context_only.require_identity().is_err());

    let session = BrowserSession {
        session_index: Some("1".to_string()),
        ..BrowserSession::default()
    };
    assert_eq!(
        session.require_identity().unwrap().session_index.as_deref(),
        Some("1")
    );
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
            user_agent: None,
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
fn chrome_uses_automatic_login_profile_by_default() {
    let browser = login_browser(BrowserKind::Chrome, "google-chrome");
    let output = Path::new("/tmp/ytm-radio/auth.json");

    assert_eq!(
        effective_login_profile_dir(output, &browser, None),
        Some(PathBuf::from("/tmp/ytm-radio/login-profile"))
    );
}

#[test]
fn non_chrome_browsers_use_normal_profile_by_default() {
    let output = Path::new("/tmp/ytm-radio/auth.json");

    assert_eq!(
        effective_login_profile_dir(output, &login_browser(BrowserKind::Dia, "dia"), None),
        None
    );
    assert_eq!(
        effective_login_profile_dir(
            output,
            &login_browser(BrowserKind::Firefox, "firefox"),
            None
        ),
        None
    );
}

#[test]
fn explicit_login_profile_overrides_automatic_default() {
    let browser = login_browser(BrowserKind::Chrome, "google-chrome");
    let output = Path::new("/tmp/ytm-radio/auth.json");
    let profile = Path::new("/tmp/custom-login-profile");

    assert_eq!(
        effective_login_profile_dir(output, &browser, Some(profile)),
        Some(profile.to_path_buf())
    );
}

#[test]
fn cdp_login_browser_arguments_include_proxy() {
    assert_eq!(
        cdp_login_browser_arguments(
            Some(Path::new("/tmp/ytm-login-profile")),
            29999,
            Some("http://127.0.0.1:7890")
        ),
        vec![
            "--remote-debugging-port=29999",
            "--remote-debugging-address=127.0.0.1",
            "--proxy-server=http://127.0.0.1:7890",
            "--user-data-dir=/tmp/ytm-login-profile",
            "--no-first-run",
            "--new-window"
        ]
    );
}

#[test]
fn resolves_login_browser_from_explicit_path() {
    let directory = temporary_test_directory();
    fs::create_dir_all(&directory).unwrap();
    let browser = directory.join("Test Browser");
    fs::write(&browser, "").unwrap();

    let resolved = resolve_login_browser(Some(browser.to_str().unwrap())).unwrap();

    assert_eq!(resolved.name(), "Test Browser");
    assert_eq!(resolved.executable, browser);
    assert_eq!(resolved.protocol(), LoginProtocol::Cdp);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn resolves_firefox_path_to_bidi_login_browser() {
    let directory = temporary_test_directory();
    fs::create_dir_all(&directory).unwrap();
    let browser = directory.join("firefox");
    fs::write(&browser, "").unwrap();

    let resolved = resolve_login_browser(Some(browser.to_str().unwrap())).unwrap();

    assert_eq!(resolved.name(), "firefox");
    assert_eq!(resolved.executable, browser);
    assert_eq!(resolved.protocol(), LoginProtocol::Bidi);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn resolves_zen_path_to_bidi_login_browser() {
    let directory = temporary_test_directory();
    fs::create_dir_all(&directory).unwrap();
    let browser = directory.join("zen");
    fs::write(&browser, "").unwrap();

    let resolved = resolve_login_browser(Some(browser.to_str().unwrap())).unwrap();

    assert_eq!(resolved.name(), "zen");
    assert_eq!(resolved.executable, browser);
    assert_eq!(resolved.protocol(), LoginProtocol::Bidi);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn recognizes_supported_default_browser_paths() {
    assert_eq!(
        supported_login_browser(Path::new("/Applications/Dia.app/Contents/MacOS/Dia")),
        Some(BrowserKind::Dia)
    );
    assert_eq!(
        supported_login_browser(Path::new(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )),
        Some(BrowserKind::Chrome)
    );
    assert_eq!(
        supported_login_browser(Path::new("/usr/bin/brave-browser")),
        Some(BrowserKind::Brave)
    );
    assert_eq!(
        supported_login_browser(Path::new("/usr/bin/firefox")),
        Some(BrowserKind::Firefox)
    );
    assert_eq!(
        supported_login_browser(Path::new("/Applications/Zen.app/Contents/MacOS/zen")),
        Some(BrowserKind::Zen)
    );
    assert_eq!(
        supported_login_browser(Path::new("/usr/bin/zen")),
        Some(BrowserKind::Zen)
    );
    assert_eq!(
        supported_login_browser(Path::new("/opt/zen-x86_64.AppImage")),
        Some(BrowserKind::Zen)
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
