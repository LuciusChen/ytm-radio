// SPDX-License-Identifier: GPL-3.0-or-later

use super::*;

const VIDEO_ID: &str = "abc123_DEF4";

#[test]
fn parses_browse_mock_command() {
    let options = parse_args(["browse", "home", "--mock", "--limit", "2"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::Browse(BrowseTarget::Home),
            auth_file: None,
            limit: 2,
            mock_data: true,
            initial_only: false,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn parses_home_initial_only_command() {
    let options =
        parse_args(["browse", "home", "--mock", "--initial-only", "--limit", "2"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::Browse(BrowseTarget::Home),
            auth_file: None,
            limit: 2,
            mock_data: true,
            initial_only: true,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn rejects_initial_only_for_non_home_browse() {
    let error = parse_args(["browse", "explore", "--initial-only", "--mock"]).unwrap_err();
    assert_eq!(
        error,
        "--initial-only is only supported for browse home".to_string()
    );
}

#[test]
fn parses_library_subtarget_command() {
    let options = parse_args(["browse", "library-albums", "--mock"]).unwrap();
    assert_eq!(
        options.command,
        Command::Browse(BrowseTarget::LibraryAlbums)
    );
}

#[test]
fn parses_explore_command() {
    let options = parse_args(["browse", "explore", "--mock"]).unwrap();
    assert_eq!(options.command, Command::Browse(BrowseTarget::Explore));
}

#[test]
fn parses_browse_id_command() {
    let options = parse_args(["browse-id", "VLPL1", "--mock", "--limit", "5"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::BrowseId {
                browse_id: "VLPL1".to_string(),
                params: None,
            },
            auth_file: None,
            limit: 5,
            mock_data: true,
            initial_only: false,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn parses_browse_id_params() {
    let options = parse_args(["browse-id", "VLPL1", "--params", "ggMCCAI%3D", "--mock"]).unwrap();
    assert_eq!(
        options.command,
        Command::BrowseId {
            browse_id: "VLPL1".to_string(),
            params: Some("ggMCCAI%3D".to_string()),
        }
    );
}

#[test]
fn parses_search_command() {
    let options = parse_args(["search", "tokyo", "--mock", "--limit", "2"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::Search {
                query: "tokyo".to_string()
            },
            auth_file: None,
            limit: 2,
            mock_data: true,
            initial_only: false,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn parses_proxy_for_request_commands() {
    let options = parse_args([
        "search",
        "tokyo",
        "--auth",
        "/tmp/auth.json",
        "--proxy",
        "socks5h://127.0.0.1:7890",
    ])
    .unwrap();
    assert_eq!(options.proxy, Some("socks5h://127.0.0.1:7890".to_string()));
}

#[test]
fn parses_fresh_for_request_commands() {
    let options = parse_args(["browse", "home", "--mock", "--fresh"]).unwrap();
    assert!(options.fresh);
}

#[test]
fn rejects_empty_proxy() {
    let error = parse_args(["search", "tokyo", "--mock", "--proxy", " "]).unwrap_err();
    assert_eq!(error, "proxy URL must not be empty".to_string());
}

#[test]
fn parses_continuation_command() {
    let options = parse_args(["continuation", "next-page", "--mock", "--limit", "3"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::Continuation {
                token: "next-page".to_string()
            },
            auth_file: None,
            limit: 3,
            mock_data: true,
            initial_only: false,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn parses_proxy_for_login_window() {
    let options = parse_args([
        "auth",
        "login-window",
        "--output",
        "/tmp/ytm/auth.json",
        "--proxy",
        "http://127.0.0.1:8888",
    ])
    .unwrap();
    assert_eq!(options.proxy, Some("http://127.0.0.1:8888".to_string()));
}

#[test]
fn parses_rate_command() {
    let options = parse_args(["rate", VIDEO_ID, "like", "--mock"]).unwrap();
    assert_eq!(
        options,
        Options {
            command: Command::Rate {
                video_id: VIDEO_ID.to_string(),
                rating: "like".to_string(),
            },
            auth_file: None,
            limit: 100,
            mock_data: true,
            initial_only: false,
            fresh: false,
            proxy: None,
        }
    );
}

#[test]
fn parses_current_track_action_commands() {
    let radio_options = parse_args(["radio", VIDEO_ID, "--mock"]).unwrap();
    assert_eq!(
        radio_options.command,
        Command::Radio {
            video_id: VIDEO_ID.to_string()
        }
    );
    let playlist_options = parse_args(["playlist-options", VIDEO_ID, "--mock"]).unwrap();
    assert_eq!(
        playlist_options.command,
        Command::PlaylistOptions {
            video_id: VIDEO_ID.to_string()
        }
    );
    let add_options = parse_args(["add-to-playlist", VIDEO_ID, "PL1", "--mock"]).unwrap();
    assert_eq!(
        add_options.command,
        Command::AddToPlaylist {
            video_id: VIDEO_ID.to_string(),
            playlist_id: "PL1".to_string()
        }
    );
    let library_options = parse_args(["library", VIDEO_ID, "toggle", "--mock"]).unwrap();
    assert_eq!(
        library_options.command,
        Command::Library {
            video_id: VIDEO_ID.to_string(),
            action: "toggle".to_string()
        }
    );
    let item_library_options = parse_args([
        "item-library",
        "VLPL1",
        "toggle",
        "--params",
        "gg",
        "--mock",
    ])
    .unwrap();
    assert_eq!(
        item_library_options.command,
        Command::ItemLibrary {
            browse_id: "VLPL1".to_string(),
            params: Some("gg".to_string()),
            action: "toggle".to_string()
        }
    );
    let subscription_options =
        parse_args(["subscription", "UC123456789", "unsubscribe", "--mock"]).unwrap();
    assert_eq!(
        subscription_options.command,
        Command::Subscription {
            browse_id: "UC123456789".to_string(),
            params: None,
            action: "unsubscribe".to_string()
        }
    );
    let status_options = parse_args(["track-status", VIDEO_ID, "--mock"]).unwrap();
    assert_eq!(
        status_options.command,
        Command::TrackStatus {
            video_id: VIDEO_ID.to_string()
        }
    );
}

#[test]
fn rejects_invalid_video_id() {
    let error = parse_args(["radio", "v1", "--mock"]).unwrap_err();
    assert!(error.contains("11-character YouTube video id"));
}

#[test]
fn rejects_unknown_rating() {
    let error = parse_args(["rate", VIDEO_ID, "favorite"]).unwrap_err();
    assert!(error.contains("unknown rating"));
}

#[test]
fn rejects_unknown_library_action() {
    let error = parse_args(["library", VIDEO_ID, "pin"]).unwrap_err();
    assert!(error.contains("unknown library action"));
}

#[test]
fn parses_login_window_command_with_defaults() {
    let options = parse_args(["auth", "login-window", "--output", "/tmp/ytm/auth.json"]).unwrap();
    assert_eq!(
        options.command,
        Command::AuthLoginWindow {
            output: PathBuf::from("/tmp/ytm/auth.json"),
            browser: None,
            profile_dir: None,
            port: DEFAULT_LOGIN_CDP_PORT,
            timeout_secs: DEFAULT_LOGIN_TIMEOUT_SECS,
            restart_running: false,
        }
    );
}

#[test]
fn parses_login_window_command_with_browser_profile_and_timeout() {
    let options = parse_args([
        "auth",
        "login-window",
        "--output",
        "/tmp/auth.json",
        "--browser",
        "brave",
        "--profile-dir",
        "/tmp/profile",
        "--port",
        "29998",
        "--timeout-secs",
        "60",
        "--restart-running",
    ])
    .unwrap();
    assert_eq!(
        options.command,
        Command::AuthLoginWindow {
            output: PathBuf::from("/tmp/auth.json"),
            browser: Some("brave".to_string()),
            profile_dir: Some(PathBuf::from("/tmp/profile")),
            port: 29998,
            timeout_secs: 60,
            restart_running: true,
        }
    );
}

#[test]
fn rejects_unknown_browse_target() {
    let error = parse_args(["browse", "albums"]).unwrap_err();
    assert!(error.contains("unknown browse target"));
}

#[test]
fn help_outputs_helper_contract() {
    let output = run(["--help"]).unwrap();
    let parsed: Value = serde_json::from_str(&output).unwrap();
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["schema"], SCHEMA_VERSION);
    assert!(parsed["data"]["usage"]
        .as_str()
        .is_some_and(|usage| usage.starts_with("usage:")));
}

#[test]
fn version_outputs_helper_contract() {
    let output = run(["version"]).unwrap();
    let parsed: Value = serde_json::from_str(&output).unwrap();
    assert_eq!(parsed["schema"], SCHEMA_VERSION);
    assert_eq!(parsed["protocol"], HELPER_PROTOCOL_VERSION);
    assert_eq!(parsed["helper-version"], HELPER_VERSION);
    assert_eq!(parsed["data"]["schema"], SCHEMA_VERSION);
    assert_eq!(parsed["data"]["protocol"], HELPER_PROTOCOL_VERSION);
    assert_eq!(parsed["data"]["helper-version"], HELPER_VERSION);
}

#[test]
fn error_envelope_preserves_explicit_error_metadata() {
    let auth: Value = serde_json::from_str(&encode_error(&HelperError::auth_required(
        "YouTube Music returned HTTP 401 Unauthorized",
    )))
    .unwrap();
    assert_eq!(auth["ok"], false);
    assert_eq!(auth["error"]["code"], "auth-required");
    assert_eq!(auth["error"]["auth-required"], true);
    assert_eq!(auth["error"]["retryable"], false);

    let network: Value = serde_json::from_str(&encode_error(&HelperError::network(
        "YouTube Music browse request failed: error sending request",
    )))
    .unwrap();
    assert_eq!(network["error"]["code"], "network");
    assert_eq!(network["error"]["auth-required"], false);
    assert_eq!(network["error"]["retryable"], true);

    let browser: Value =
        serde_json::from_str(&encode_error(&HelperError::browser_restart_required(
            "Zen is already running without WebDriver BiDi on 127.0.0.1:29317",
        )))
        .unwrap();
    assert_eq!(browser["error"]["code"], "browser-restart-required");
    assert_eq!(browser["error"]["auth-required"], false);
    assert_eq!(browser["error"]["retryable"], false);
}

#[test]
fn version_rejects_request_options() {
    let error = parse_args(["version", "--auth", "/tmp/auth.json"]).unwrap_err();
    assert_eq!(error, "version does not accept request options".to_string());
}

#[test]
fn usage_hides_internal_mock_option() {
    assert!(!usage().contains("--mock"));
}

#[test]
fn mock_browse_outputs_track_items() {
    let output = run(["browse", "library-songs", "--mock", "--limit", "1"]).unwrap();
    assert!(output.contains(r#""schema":1"#));
    assert!(output.contains(r#""id":"ytm:library:songs""#));
    assert!(output.contains(r#""type":"track""#));
    assert!(!output.contains(r#""type":"playlist""#));
}

#[test]
fn mock_library_outputs_sections() {
    let output = run(["browse", "library", "--mock", "--limit", "2"]).unwrap();
    assert!(output.contains(r#""id":"ytm:library:songs""#));
    assert!(output.contains(r#""id":"ytm:library:albums""#));
    assert!(output.contains(r#""id":"ytm:library:playlists""#));
}

#[test]
fn mock_explore_outputs_sections() {
    let output = run(["browse", "explore", "--mock", "--limit", "2"]).unwrap();
    assert!(output.contains(r#""id":"ytm:explore:mock:new-releases""#));
    assert!(output.contains(r#""kind":"youtube-music-explore-section""#));
    assert!(output.contains("Mock New Release"));
}

#[test]
fn mock_search_outputs_results() {
    let output = run(["search", "tokyo", "--mock", "--limit", "5"]).unwrap();
    assert!(output.contains(r#""kind":"youtube-music-search""#));
    assert!(output.contains("tokyo result"));
    assert!(output.contains("tokyo album"));
    assert!(output.contains("tokyo artist"));
    assert!(output.contains("tokyo podcast"));
    assert!(output.contains("tokyo playlist"));
}

#[test]
fn mock_rate_outputs_rating() {
    let output = run(["rate", VIDEO_ID, "dislike", "--mock"]).unwrap();
    assert!(output.contains(r#""schema":1"#));
    assert!(output.contains(r#""video-id":"abc123_DEF4""#));
    assert!(output.contains(r#""rating":"dislike""#));
}

#[test]
fn mock_current_track_actions_output_data() {
    let radio_output = run(["radio", VIDEO_ID, "--mock", "--limit", "2"]).unwrap();
    assert!(radio_output.contains(r#""kind":"youtube-music-radio""#));
    assert!(radio_output.contains(r#""id":"abc123_DEF4""#));

    let options_output = run(["playlist-options", VIDEO_ID, "--mock"]).unwrap();
    assert!(options_output.contains(r#""playlist-id":"mock-playlist-1""#));

    let add_output = run(["add-to-playlist", VIDEO_ID, "mock-playlist-1", "--mock"]).unwrap();
    assert!(add_output.contains(r#""playlist-id":"mock-playlist-1""#));

    let library_output = run(["library", VIDEO_ID, "toggle", "--mock"]).unwrap();
    assert!(library_output.contains(r#""in-library":true"#));
    assert!(library_output.contains(r#""like-status":"like""#));

    let item_library_output = run(["item-library", "VLPL1", "toggle", "--mock"]).unwrap();
    assert!(item_library_output.contains(r#""browse-id":"VLPL1""#));
    assert!(item_library_output.contains(r#""in-library":true"#));

    let subscription_output = run(["subscription", "UC123456789", "toggle", "--mock"]).unwrap();
    assert!(subscription_output.contains(r#""browse-id":"UC123456789""#));
    assert!(subscription_output.contains(r#""subscribed":true"#));

    let status_output = run(["track-status", VIDEO_ID, "--mock"]).unwrap();
    assert!(status_output.contains(r#""in-library":true"#));
    assert!(status_output.contains(r#""like-status":"like""#));
}

#[test]
fn mock_browse_id_outputs_detail_source() {
    let output = run(["browse-id", "VLPL1", "--mock", "--limit", "2"]).unwrap();
    assert!(output.contains(r#""id":"ytm:browse:VLPL1""#));
    assert!(output.contains(r#""kind":"youtube-music-playlist""#));
    assert!(output.contains("Mock Detail Track"));
}
