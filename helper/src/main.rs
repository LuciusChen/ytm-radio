// SPDX-License-Identifier: GPL-3.0-or-later

mod auth;
mod ytmusic;

use auth::{login_window, AuthConfig};
use serde::Serialize;
use serde_json::json;
#[cfg(test)]
use serde_json::Value;
use std::env;
use std::path::PathBuf;
use std::process;
use std::time::Duration;
use ytmusic::{
    add_to_playlist, bootstrap_cache_path, browse, browse_id as browse_detail, clear_account_cache,
    clear_response_cache, continuation, item_library, library, playlist_options, radio, rate,
    search, subscription, track_status, BrowseTarget,
};

const SCHEMA_VERSION: u32 = 1;
const HELPER_PROTOCOL_VERSION: u32 = 1;
const HELPER_VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_LOGIN_CDP_PORT: u16 = 29317;
const DEFAULT_LOGIN_TIMEOUT_SECS: u64 = 180;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    Version,
    AuthCheck,
    AuthLoginWindow {
        output: PathBuf,
        browser: Option<String>,
        profile_dir: Option<PathBuf>,
        port: u16,
        timeout_secs: u64,
        restart_running: bool,
    },
    Browse(BrowseTarget),
    BrowseId {
        browse_id: String,
        params: Option<String>,
    },
    Continuation {
        token: String,
    },
    Search {
        query: String,
    },
    Rate {
        video_id: String,
        rating: String,
    },
    Radio {
        video_id: String,
    },
    PlaylistOptions {
        video_id: String,
    },
    AddToPlaylist {
        video_id: String,
        playlist_id: String,
    },
    Library {
        video_id: String,
        action: String,
    },
    ItemLibrary {
        browse_id: String,
        params: Option<String>,
        action: String,
    },
    Subscription {
        browse_id: String,
        params: Option<String>,
        action: String,
    },
    TrackStatus {
        video_id: String,
    },
}

impl Command {
    fn mutation_p(&self) -> bool {
        matches!(
            self,
            Self::Rate { .. }
                | Self::AddToPlaylist { .. }
                | Self::Library { .. }
                | Self::ItemLibrary { .. }
                | Self::Subscription { .. }
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Options {
    command: Command,
    auth_file: Option<PathBuf>,
    limit: usize,
    mock_data: bool,
    initial_only: bool,
    fresh: bool,
    proxy: Option<String>,
}

#[derive(Serialize)]
struct Envelope<T> {
    ok: bool,
    schema: u32,
    protocol: u32,
    #[serde(rename = "helper-version")]
    helper_version: &'static str,
    data: T,
    warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
struct ErrorPayload {
    code: &'static str,
    message: String,
    retryable: bool,
    #[serde(rename = "auth-required")]
    auth_required: bool,
}

#[derive(Serialize)]
struct ErrorEnvelope {
    ok: bool,
    schema: u32,
    protocol: u32,
    #[serde(rename = "helper-version")]
    helper_version: &'static str,
    error: ErrorPayload,
    warnings: Vec<String>,
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if help_requested(&args) {
        println!("{}", usage());
        return;
    }
    match run(args) {
        Ok(output) => println!("{output}"),
        Err(error) => {
            eprintln!("{error}");
            println!("{}", encode_error(&error));
            process::exit(1);
        }
    }
}

fn encode_error(message: &str) -> String {
    serde_json::to_string(&ErrorEnvelope {
        ok: false,
        schema: SCHEMA_VERSION,
        protocol: HELPER_PROTOCOL_VERSION,
        helper_version: HELPER_VERSION,
        error: classify_error(message),
        warnings: Vec::new(),
    })
    .expect("error envelope is serializable")
}

fn classify_error(message: &str) -> ErrorPayload {
    let lowercase = message.to_ascii_lowercase();
    let browser_restart_required = lowercase.contains("already running without");
    let auth_required = lowercase.contains("http 401")
        || lowercase.contains("http 403")
        || lowercase.contains("required authentication credential")
        || lowercase.contains("auth file")
        || lowercase.contains("auth cookie")
        || lowercase.contains("unsupported auth source")
        || lowercase.contains("missing --auth");
    let network = lowercase.contains("error sending request")
        || lowercase.contains("connection")
        || lowercase.contains("timed out")
        || lowercase.contains("timeout")
        || lowercase.contains("cannot load youtube music");
    let remote_retryable = lowercase.contains("http 429") || lowercase.contains("http 5");
    let invalid_request = lowercase.starts_with("unknown ")
        || lowercase.starts_with("expected ")
        || lowercase.starts_with("missing option")
        || lowercase.starts_with("invalid ")
        || lowercase.contains("must not be empty")
        || lowercase.contains("must be greater than zero")
        || lowercase.contains("does not accept request options")
        || lowercase.contains("options require");
    let (code, retryable) = if browser_restart_required {
        ("browser-restart-required", false)
    } else if auth_required {
        ("auth-required", false)
    } else if network {
        ("network", true)
    } else if remote_retryable {
        ("remote-response", true)
    } else if invalid_request {
        ("invalid-request", false)
    } else {
        ("helper-failure", false)
    };
    ErrorPayload {
        code,
        message: message.to_string(),
        retryable,
        auth_required,
    }
}

fn help_requested(args: &[String]) -> bool {
    matches!(
        args,
        [argument] if matches!(argument.as_str(), "help" | "--help" | "-h")
    )
}

fn run<I>(args: I) -> Result<String, String>
where
    I: IntoIterator,
    I::Item: Into<String>,
{
    let options = parse_args(args)?;
    let proxy = options.proxy.as_deref();
    if options.fresh && !options.mock_data {
        let auth_path = required_auth_path(&options)?;
        clear_response_cache(&bootstrap_cache_path(auth_path))?;
    }
    let data = match &options.command {
        Command::Version => {
            json!({
                "schema": SCHEMA_VERSION,
                "protocol": HELPER_PROTOCOL_VERSION,
                "helper-version": HELPER_VERSION
            })
        }
        Command::AuthCheck => {
            let path = required_auth_path(&options)?;
            let config = AuthConfig::load(path)?;
            json!({
                "auth": {
                    "configured": true,
                    "source": config.source,
                    "path": path
                }
            })
        }
        Command::AuthLoginWindow {
            output,
            browser,
            profile_dir,
            port,
            timeout_secs,
            restart_running,
        } => {
            let config = login_window(
                output,
                browser.as_deref(),
                profile_dir.as_deref(),
                *port,
                Duration::from_secs(*timeout_secs),
                *restart_running,
                proxy,
            )?;
            if let Err(error) = clear_account_cache(&bootstrap_cache_path(output)) {
                eprintln!("ytm-radio-helper cache-invalidation-error={error}");
            }
            json!({
                "auth": {
                    "configured": true,
                    "source": config.source,
                    "path": output,
                    "profile": profile_dir
                }
            })
        }
        #[cfg(test)]
        Command::Browse(target) if options.mock_data => {
            mock_browse(target, options.limit, options.initial_only)
        }
        Command::Browse(target) => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            browse(
                target,
                options.limit,
                &auth,
                options.initial_only,
                Some(&cache_path),
                proxy,
            )?
        }
        #[cfg(test)]
        Command::BrowseId { browse_id, .. } if options.mock_data => {
            mock_browse_id(browse_id, options.limit)
        }
        Command::BrowseId { browse_id, params } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            browse_detail(
                browse_id,
                params.as_deref(),
                options.limit,
                &auth,
                Some(&cache_path),
                proxy,
            )?
        }
        #[cfg(test)]
        Command::Continuation { token } if options.mock_data => {
            mock_continuation(token, options.limit)
        }
        Command::Continuation { token } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            continuation(token, options.limit, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::Search { query } if options.mock_data => mock_search(query, options.limit),
        Command::Search { query } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            search(query, options.limit, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::Rate { video_id, rating } if options.mock_data => {
            json!({ "video-id": video_id, "rating": rating })
        }
        Command::Rate { video_id, rating } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            rate(video_id, rating, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::Radio { video_id } if options.mock_data => mock_radio(video_id, options.limit),
        Command::Radio { video_id } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            radio(video_id, options.limit, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::PlaylistOptions { video_id } if options.mock_data => {
            mock_playlist_options(video_id)
        }
        Command::PlaylistOptions { video_id } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            playlist_options(video_id, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::AddToPlaylist {
            video_id,
            playlist_id,
        } if options.mock_data => {
            json!({ "video-id": video_id, "playlist-id": playlist_id })
        }
        Command::AddToPlaylist {
            video_id,
            playlist_id,
        } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            add_to_playlist(video_id, playlist_id, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::Library { video_id, action } if options.mock_data => {
            json!({
                "video-id": video_id,
                "in-library": action != "remove",
                "like-status": "like",
                "action": action,
                "changed": true
            })
        }
        Command::Library { video_id, action } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            library(video_id, action, &auth, Some(&cache_path), proxy)?
        }
        #[cfg(test)]
        Command::ItemLibrary {
            browse_id, action, ..
        } if options.mock_data => {
            json!({
                "browse-id": browse_id,
                "in-library": action != "remove",
                "action": action,
                "changed": true
            })
        }
        Command::ItemLibrary {
            browse_id,
            params,
            action,
        } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            item_library(
                browse_id,
                params.as_deref(),
                action,
                &auth,
                Some(&cache_path),
                proxy,
            )?
        }
        #[cfg(test)]
        Command::Subscription {
            browse_id, action, ..
        } if options.mock_data => {
            json!({
                "browse-id": browse_id,
                "subscribed": action != "unsubscribe",
                "action": action,
                "changed": true
            })
        }
        Command::Subscription {
            browse_id,
            params,
            action,
        } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            subscription(
                browse_id,
                params.as_deref(),
                action,
                &auth,
                Some(&cache_path),
                proxy,
            )?
        }
        #[cfg(test)]
        Command::TrackStatus { video_id } if options.mock_data => {
            json!({ "video-id": video_id, "in-library": true, "like-status": "like" })
        }
        Command::TrackStatus { video_id } => {
            let (auth, cache_path) = load_auth_with_cache_path(&options)?;
            track_status(video_id, &auth, Some(&cache_path), proxy)?
        }
    };
    if options.command.mutation_p() && !options.mock_data {
        let auth_path = required_auth_path(&options)?;
        if let Err(error) = clear_response_cache(&bootstrap_cache_path(auth_path)) {
            eprintln!("ytm-radio-helper cache-invalidation-error={error}");
        }
    }
    serde_json::to_string(&Envelope {
        ok: true,
        schema: SCHEMA_VERSION,
        protocol: HELPER_PROTOCOL_VERSION,
        helper_version: HELPER_VERSION,
        data,
        warnings: Vec::new(),
    })
    .map_err(|error| format!("cannot encode response: {error}"))
}

fn required_auth_path(options: &Options) -> Result<&std::path::Path, String> {
    options
        .auth_file
        .as_deref()
        .ok_or_else(|| "missing --auth FILE".to_string())
}

fn load_auth_with_cache_path(options: &Options) -> Result<(AuthConfig, PathBuf), String> {
    let auth_path = required_auth_path(options)?;
    Ok((
        AuthConfig::load(auth_path)?,
        bootstrap_cache_path(auth_path),
    ))
}

fn parse_args<I>(args: I) -> Result<Options, String>
where
    I: IntoIterator,
    I::Item: Into<String>,
{
    let mut args: Vec<String> = args.into_iter().map(Into::into).collect();
    if args.is_empty() {
        return Err(usage());
    }

    let command = match args.remove(0).as_str() {
        "version" => Command::Version,
        "auth" => parse_auth_command(&mut args)?,
        "browse" => parse_browse_command(&mut args)?,
        "browse-id" => parse_browse_id_command(&mut args)?,
        "continuation" => parse_continuation_command(&mut args)?,
        "search" => parse_search_command(&mut args)?,
        "rate" => parse_rate_command(&mut args)?,
        "radio" => parse_video_id_command(&mut args, "radio")?,
        "playlist-options" => parse_video_id_command(&mut args, "playlist-options")?,
        "add-to-playlist" => parse_add_to_playlist_command(&mut args)?,
        "library" => parse_library_command(&mut args)?,
        "item-library" => parse_item_library_command(&mut args)?,
        "subscription" => parse_subscription_command(&mut args)?,
        "track-status" => parse_track_status_command(&mut args)?,
        "help" | "--help" | "-h" => return Err(usage()),
        other => return Err(format!("unknown command `{other}`")),
    };

    let mut auth_file = None;
    let mut limit = 100;
    #[cfg(test)]
    let mut mock_data = false;
    #[cfg(not(test))]
    let mock_data = false;
    let mut browser = None;
    let mut output = None;
    let mut port = None;
    let mut profile_dir = None;
    let mut browse_params = None;
    let mut initial_only = false;
    let mut fresh = false;
    let mut timeout_secs = None;
    let mut restart_running = false;
    let mut proxy = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--auth" => auth_file = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--limit" => {
                let value = option_value(&args, &mut index)?;
                limit = value
                    .parse::<usize>()
                    .map_err(|_| format!("invalid limit `{value}`"))?;
                if limit == 0 {
                    return Err("limit must be greater than zero".to_string());
                }
            }
            #[cfg(test)]
            "--mock" => mock_data = true,
            "--browser" => browser = Some(option_value(&args, &mut index)?.to_string()),
            "--output" => output = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--port" => {
                let value = option_value(&args, &mut index)?;
                port = Some(
                    value
                        .parse::<u16>()
                        .map_err(|_| format!("invalid port `{value}`"))?,
                );
            }
            "--profile-dir" => profile_dir = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--timeout-secs" => {
                let value = option_value(&args, &mut index)?;
                timeout_secs = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| format!("invalid timeout `{value}`"))?,
                );
            }
            "--params" => {
                let value = option_value(&args, &mut index)?;
                if value.trim().is_empty() {
                    return Err("browse params must not be empty".to_string());
                }
                browse_params = Some(value.to_string());
            }
            "--initial-only" => initial_only = true,
            "--fresh" => fresh = true,
            "--restart-running" => restart_running = true,
            "--proxy" => {
                let value = option_value(&args, &mut index)?.trim();
                if value.is_empty() {
                    return Err("proxy URL must not be empty".to_string());
                }
                proxy = Some(value.to_string());
            }
            other => return Err(format!("unknown option `{other}`")),
        }
        index += 1;
    }

    let command = match command {
        Command::AuthLoginWindow { .. } => {
            if browse_params.is_some() || initial_only || fresh || mock_data || auth_file.is_some()
            {
                return Err("browse options require a browse action".to_string());
            }
            let output = output.ok_or_else(|| "missing --output FILE".to_string())?;
            Command::AuthLoginWindow {
                output,
                browser,
                profile_dir,
                port: port.unwrap_or(DEFAULT_LOGIN_CDP_PORT),
                timeout_secs: timeout_secs.unwrap_or(DEFAULT_LOGIN_TIMEOUT_SECS),
                restart_running,
            }
        }
        Command::Version => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || restart_running
                || browse_params.is_some()
                || initial_only
                || fresh
                || mock_data
                || auth_file.is_some()
                || proxy.is_some()
            {
                return Err("version does not accept request options".to_string());
            }
            Command::Version
        }
        Command::BrowseId { browse_id, .. } => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || initial_only
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            Command::BrowseId {
                browse_id,
                params: browse_params,
            }
        }
        Command::ItemLibrary {
            browse_id, action, ..
        } => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || initial_only
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            Command::ItemLibrary {
                browse_id,
                params: browse_params,
                action,
            }
        }
        Command::Subscription {
            browse_id, action, ..
        } => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || initial_only
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            Command::Subscription {
                browse_id,
                params: browse_params,
                action,
            }
        }
        Command::Browse(target) => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || browse_params.is_some()
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            if initial_only && !matches!(target, BrowseTarget::Home) {
                return Err("--initial-only is only supported for browse home".to_string());
            }
            Command::Browse(target)
        }
        Command::AuthCheck => {
            if proxy.is_some() {
                return Err("proxy options require a YouTube Music request action".to_string());
            }
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            if browse_params.is_some() || initial_only || fresh || mock_data {
                return Err("browse options require a browse action".to_string());
            }
            Command::AuthCheck
        }
        other => {
            if browser.is_some()
                || output.is_some()
                || port.is_some()
                || profile_dir.is_some()
                || timeout_secs.is_some()
                || browse_params.is_some()
                || initial_only
                || restart_running
            {
                return Err("auth options require an auth action".to_string());
            }
            other
        }
    };

    Ok(Options {
        command,
        auth_file,
        limit,
        mock_data,
        initial_only,
        fresh,
        proxy,
    })
}

fn parse_auth_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(action) = args.first().cloned() else {
        return Err("expected an auth action".to_string());
    };
    args.remove(0);
    match action.as_str() {
        "check" => Ok(Command::AuthCheck),
        "login-window" => Ok(Command::AuthLoginWindow {
            output: PathBuf::new(),
            browser: None,
            profile_dir: None,
            port: DEFAULT_LOGIN_CDP_PORT,
            timeout_secs: DEFAULT_LOGIN_TIMEOUT_SECS,
            restart_running: false,
        }),
        other => Err(format!("unknown auth action `{other}`")),
    }
}

fn parse_browse_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(target) = args.first().cloned() else {
        return Err("expected browse target".to_string());
    };
    args.remove(0);
    Ok(Command::Browse(match target.as_str() {
        "home" => BrowseTarget::Home,
        "explore" => BrowseTarget::Explore,
        "library" => BrowseTarget::Library,
        "library-songs" => BrowseTarget::LibrarySongs,
        "library-albums" => BrowseTarget::LibraryAlbums,
        "library-artists" => BrowseTarget::LibraryArtists,
        "library-playlists" => BrowseTarget::LibraryPlaylists,
        "liked" => BrowseTarget::Liked,
        other => return Err(format!("unknown browse target `{other}`")),
    }))
}

fn parse_browse_id_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(browse_id) = args.first().cloned() else {
        return Err("expected browse id".to_string());
    };
    args.remove(0);
    if browse_id.trim().is_empty() {
        return Err("browse id must not be empty".to_string());
    }
    Ok(Command::BrowseId {
        browse_id,
        params: None,
    })
}

fn parse_continuation_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(token) = args.first().cloned() else {
        return Err("expected continuation token".to_string());
    };
    args.remove(0);
    if token.trim().is_empty() {
        return Err("continuation token must not be empty".to_string());
    }
    Ok(Command::Continuation { token })
}

fn parse_search_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(query) = args.first().cloned() else {
        return Err("expected search query".to_string());
    };
    args.remove(0);
    if query.trim().is_empty() {
        return Err("search query must not be empty".to_string());
    }
    Ok(Command::Search { query })
}

fn parse_rate_command(args: &mut Vec<String>) -> Result<Command, String> {
    let video_id = parse_required_video_id(args)?;
    let Some(rating) = args.first().cloned() else {
        return Err("expected rating".to_string());
    };
    args.remove(0);
    match rating.as_str() {
        "like" | "dislike" | "indifferent" => Ok(Command::Rate { video_id, rating }),
        other => Err(format!("unknown rating `{other}`")),
    }
}

fn parse_video_id_command(args: &mut Vec<String>, command: &str) -> Result<Command, String> {
    let video_id = parse_required_video_id(args)?;
    match command {
        "radio" => Ok(Command::Radio { video_id }),
        "playlist-options" => Ok(Command::PlaylistOptions { video_id }),
        other => Err(format!("unknown video id command `{other}`")),
    }
}

fn parse_add_to_playlist_command(args: &mut Vec<String>) -> Result<Command, String> {
    let video_id = parse_required_video_id(args)?;
    let Some(playlist_id) = args.first().cloned() else {
        return Err("expected playlist id".to_string());
    };
    args.remove(0);
    if playlist_id.trim().is_empty() {
        return Err("playlist id must not be empty".to_string());
    }
    Ok(Command::AddToPlaylist {
        video_id,
        playlist_id,
    })
}

fn parse_library_command(args: &mut Vec<String>) -> Result<Command, String> {
    let video_id = parse_required_video_id(args)?;
    let Some(action) = args.first().cloned() else {
        return Err("expected library action".to_string());
    };
    args.remove(0);
    match action.as_str() {
        "toggle" | "save" | "remove" => Ok(Command::Library { video_id, action }),
        other => Err(format!("unknown library action `{other}`")),
    }
}

fn parse_item_library_command(args: &mut Vec<String>) -> Result<Command, String> {
    let browse_id = parse_required_browse_id(args)?;
    let action = parse_required_action(args, "library")?;
    match action.as_str() {
        "toggle" | "save" | "remove" => Ok(Command::ItemLibrary {
            browse_id,
            params: None,
            action,
        }),
        other => Err(format!("unknown library action `{other}`")),
    }
}

fn parse_subscription_command(args: &mut Vec<String>) -> Result<Command, String> {
    let browse_id = parse_required_browse_id(args)?;
    let action = parse_required_action(args, "subscription")?;
    match action.as_str() {
        "toggle" | "subscribe" | "unsubscribe" => Ok(Command::Subscription {
            browse_id,
            params: None,
            action,
        }),
        other => Err(format!("unknown subscription action `{other}`")),
    }
}

fn parse_track_status_command(args: &mut Vec<String>) -> Result<Command, String> {
    Ok(Command::TrackStatus {
        video_id: parse_required_video_id(args)?,
    })
}

fn parse_required_browse_id(args: &mut Vec<String>) -> Result<String, String> {
    let Some(browse_id) = args.first().cloned() else {
        return Err("expected browse id".to_string());
    };
    args.remove(0);
    if browse_id.trim().is_empty() {
        return Err("browse id must not be empty".to_string());
    }
    Ok(browse_id)
}

fn parse_required_action(args: &mut Vec<String>, command: &str) -> Result<String, String> {
    let Some(action) = args.first().cloned() else {
        return Err(format!("expected {command} action"));
    };
    args.remove(0);
    Ok(action)
}

fn parse_required_video_id(args: &mut Vec<String>) -> Result<String, String> {
    let Some(video_id) = args.first().cloned() else {
        return Err("expected video id".to_string());
    };
    args.remove(0);
    if !is_youtube_video_id(&video_id) {
        return Err("video id must be an 11-character YouTube video id".to_string());
    }
    Ok(video_id)
}

fn is_youtube_video_id(video_id: &str) -> bool {
    video_id.len() == 11
        && video_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn option_value<'a>(args: &'a [String], index: &mut usize) -> Result<&'a str, String> {
    *index += 1;
    args.get(*index)
        .map(String::as_str)
        .ok_or_else(|| "missing option value".to_string())
}

fn usage() -> String {
    [
        "usage:",
        "  ytm-radio-helper version",
        "  ytm-radio-helper auth check --auth FILE",
        "  ytm-radio-helper auth login-window --output FILE [--browser BROWSER] [--profile-dir DIR] [--port N] [--timeout-secs N] [--restart-running] [--proxy URL]",
        "  ytm-radio-helper browse home --auth FILE [--limit N] [--initial-only] [--fresh]",
        "  ytm-radio-helper browse explore|library|library-songs|library-albums|library-artists|library-playlists|liked --auth FILE [--limit N] [--fresh]",
        "  ytm-radio-helper browse-id BROWSE_ID --auth FILE [--params PARAMS] [--limit N] [--fresh]",
        "  ytm-radio-helper continuation TOKEN --auth FILE [--limit N] [--fresh]",
        "  ytm-radio-helper search QUERY --auth FILE [--limit N] [--fresh]",
        "  ytm-radio-helper rate VIDEO_ID like|dislike|indifferent --auth FILE",
        "  ytm-radio-helper radio VIDEO_ID --auth FILE [--limit N]",
        "  ytm-radio-helper playlist-options VIDEO_ID --auth FILE",
        "  ytm-radio-helper add-to-playlist VIDEO_ID PLAYLIST_ID --auth FILE",
        "  ytm-radio-helper library VIDEO_ID toggle|save|remove --auth FILE",
        "  ytm-radio-helper item-library BROWSE_ID toggle|save|remove --auth FILE [--params PARAMS]",
        "  ytm-radio-helper subscription BROWSE_ID toggle|subscribe|unsubscribe --auth FILE [--params PARAMS]",
        "  ytm-radio-helper track-status VIDEO_ID --auth FILE",
        "",
        "options:",
        "  --proxy URL  proxy YouTube Music requests and supported login browsers",
    ]
    .join("\n")
}

#[cfg(test)]
fn mock_browse(target: &BrowseTarget, limit: usize, initial_only: bool) -> Value {
    if matches!(target, BrowseTarget::Home) {
        return mock_home_browse(limit, initial_only);
    }
    if matches!(target, BrowseTarget::Explore) {
        return mock_explore_browse(limit);
    }
    if matches!(target, BrowseTarget::Library) {
        return mock_library_browse(limit);
    }
    let (id, kind, title, url, track_id, track_title) = match target {
        BrowseTarget::Home => (
            "ytm:home:mock",
            "youtube-music-home",
            "Mock Home",
            "ytm://home/mock",
            "mock-home-track",
            "Mock Home Track",
        ),
        BrowseTarget::Explore => unreachable!(),
        BrowseTarget::Library => unreachable!(),
        BrowseTarget::LibrarySongs => (
            "ytm:library:songs",
            "youtube-music-library",
            "Library Songs",
            "ytm://library/songs",
            "mock-library-track",
            "Mock Library Track",
        ),
        BrowseTarget::LibraryAlbums => (
            "ytm:library:albums",
            "youtube-music-library",
            "Library Albums",
            "ytm://library/albums",
            "mock-album-track",
            "Mock Album Track",
        ),
        BrowseTarget::LibraryArtists => (
            "ytm:library:artists",
            "youtube-music-library",
            "Library Artists",
            "ytm://library/artists",
            "mock-artist-track",
            "Mock Artist Track",
        ),
        BrowseTarget::LibraryPlaylists => (
            "ytm:library:playlists",
            "youtube-music-library",
            "Library Playlists",
            "ytm://library/playlists",
            "mock-playlist-track",
            "Mock Playlist Track",
        ),
        BrowseTarget::Liked => (
            "ytm:library:liked",
            "youtube-music-liked",
            "Liked Music",
            "ytm://library/liked",
            "mock-liked-track",
            "Mock Liked Track",
        ),
    };
    let mut items = vec![json!({
        "type": "track",
        "id": track_id,
        "title": track_title,
        "url": format!("https://music.youtube.com/watch?v={track_id}"),
        "artist": "Mock Artist",
        "album": "Mock Album",
        "duration": 180,
        "thumbnail-url": null
    })];
    if limit.clamp(1, 2) > 1 {
        items.push(json!({
            "type": "playlist",
            "id": "mock-playlist",
            "title": "Mock Playlist",
            "url": "https://music.youtube.com/playlist?list=mock-playlist",
            "browse-id": "VLmock-playlist",
            "playlist-id": "mock-playlist",
            "subtitle": "Playlist",
            "thumbnail-url": null
        }));
    }
    json!({
        "sources": [{
            "id": id,
            "kind": kind,
            "title": title,
            "url": url,
            "items": items,
            "continuation": null
        }]
    })
}

#[cfg(test)]
fn mock_search(query: &str, limit: usize) -> Value {
    let items = vec![
        json!({
            "type": "track",
            "id": "mock-search-track",
            "title": format!("{query} result"),
            "url": "https://music.youtube.com/watch?v=mock-search-track",
            "artist": "Mock Artist",
            "album": "Mock Album",
            "duration": 180,
            "thumbnail-url": null
        }),
        json!({
            "type": "album",
            "id": "mock-search-album",
            "title": format!("{query} album"),
            "url": "https://music.youtube.com/browse/mock-search-album",
            "browse-id": "mock-search-album",
            "playlist-id": null,
            "subtitle": "Album - Mock Artist",
            "thumbnail-url": null
        }),
        json!({
            "type": "artist",
            "id": "UCmock-search-artist",
            "title": format!("{query} artist"),
            "url": "https://music.youtube.com/browse/UCmock-search-artist",
            "browse-id": "UCmock-search-artist",
            "playlist-id": null,
            "subtitle": "Artist",
            "thumbnail-url": null
        }),
        json!({
            "type": "podcast",
            "id": "MPSPmock-search-podcast",
            "title": format!("{query} podcast"),
            "url": "https://music.youtube.com/browse/MPSPmock-search-podcast",
            "browse-id": "MPSPmock-search-podcast",
            "playlist-id": null,
            "subtitle": "Podcast",
            "thumbnail-url": null
        }),
        json!({
            "type": "playlist",
            "id": "mock-search-playlist",
            "title": format!("{query} playlist"),
            "url": "https://music.youtube.com/playlist?list=mock-search-playlist",
            "browse-id": "VLmock-search-playlist",
            "playlist-id": "mock-search-playlist",
            "subtitle": "Playlist",
            "thumbnail-url": null
        }),
    ];
    json!({
        "sources": [{
            "id": "ytm:search:mock",
            "kind": "youtube-music-search",
            "title": format!("Search: {query}"),
            "url": "ytm://search/mock",
            "items": items.into_iter().take(limit).collect::<Vec<_>>(),
            "continuation": null
        }]
    })
}

#[cfg(test)]
fn mock_radio(video_id: &str, limit: usize) -> Value {
    let items = (0..limit.min(3))
        .map(|index| {
            let id = if index == 0 {
                video_id.to_string()
            } else {
                format!("mockRADIO{index:02}")
            };
            json!({
                "type": "track",
                "id": id,
                "title": format!("Mock Radio Track {}", index + 1),
                "url": format!("https://music.youtube.com/watch?v={id}"),
                "artist": "Mock Artist",
                "album": null,
                "duration": 180,
                "thumbnail-url": null,
                "like-status": null,
                "in-library": false
            })
        })
        .collect::<Vec<_>>();
    json!({
        "sources": [{
            "id": format!("ytm:radio:{video_id}"),
            "kind": "youtube-music-radio",
            "title": format!("Radio: {video_id}"),
            "url": format!("https://music.youtube.com/watch?v={video_id}&list=RDAMVM{video_id}"),
            "items": items,
            "continuation": "mock-radio-continuation"
        }]
    })
}

#[cfg(test)]
fn mock_playlist_options(_video_id: &str) -> Value {
    json!({
        "title": "Add to playlist",
        "options": [
            {
                "playlist-id": "mock-playlist-1",
                "title": "Mock Playlist 1",
                "subtitle": "Private",
                "thumbnail-url": null,
                "selected": false,
                "privacy-status": "PRIVATE"
            },
            {
                "playlist-id": "mock-playlist-2",
                "title": "Mock Playlist 2",
                "subtitle": "Public",
                "thumbnail-url": null,
                "selected": false,
                "privacy-status": "PUBLIC"
            }
        ],
        "can-create-playlist": false
    })
}

#[cfg(test)]
fn mock_library_browse(limit: usize) -> Value {
    let songs = mock_browse(&BrowseTarget::LibrarySongs, limit, false)
        .pointer("/sources/0")
        .cloned()
        .unwrap_or(Value::Null);
    let albums = json!({
        "id": "ytm:library:albums",
        "kind": "youtube-music-library-section",
        "title": "Albums",
        "url": "ytm://library/albums",
        "items": [{
            "type": "album",
            "id": "mock-library-album",
            "title": "Mock Album",
            "url": "https://music.youtube.com/browse/mock-library-album",
            "browse-id": "mock-library-album",
            "playlist-id": null,
            "subtitle": "Mock Artist",
            "thumbnail-url": null
        }],
        "continuation": null
    });
    let playlists = json!({
        "id": "ytm:library:playlists",
        "kind": "youtube-music-library-section",
        "title": "Playlists",
        "url": "ytm://library/playlists",
        "items": [{
            "type": "playlist",
            "id": "mock-library-playlist",
            "title": "Mock Playlist",
            "url": "https://music.youtube.com/playlist?list=mock-library-playlist",
            "browse-id": "VLmock-library-playlist",
            "playlist-id": "mock-library-playlist",
            "subtitle": "Playlist",
            "thumbnail-url": null
        }],
        "continuation": null
    });
    json!({ "sources": [songs, albums, playlists] })
}

#[cfg(test)]
fn mock_home_browse(limit: usize, initial_only: bool) -> Value {
    let item_limit = limit.clamp(1, 2);
    let mut listen_again = vec![json!({
        "type": "track",
        "id": "mock-home-track",
        "title": "Mock Home Track",
        "url": "https://music.youtube.com/watch?v=mock-home-track",
        "artist": "Mock Artist",
        "album": "Mock Album",
        "duration": 180,
        "thumbnail-url": null
    })];
    if item_limit > 1 {
        listen_again.push(json!({
            "type": "album",
            "id": "mock-album",
            "title": "Mock Album",
            "url": "https://music.youtube.com/browse/mock-album",
            "browse-id": "mock-album",
            "playlist-id": null,
            "subtitle": "Mock Artist",
            "thumbnail-url": null
        }));
    }
    let mut sources = vec![json!({
            "id": "ytm:home:mock:listen-again",
            "kind": "youtube-music-home-section",
            "title": "Listen again",
            "url": "ytm://home/mock",
            "items": listen_again,
            "continuation": null
    })];
    if !initial_only {
        sources.push(json!({
            "id": "ytm:home:mock:mixed-for-you",
            "kind": "youtube-music-home-section",
            "title": "Mixed for you",
            "url": "ytm://home/mock",
            "items": [{
                "type": "playlist",
                "id": "mock-mix",
                "title": "Mock Mix",
                "url": "https://music.youtube.com/playlist?list=mock-mix",
                "browse-id": "VLmock-mix",
                "playlist-id": "mock-mix",
                "subtitle": "Playlist",
                "thumbnail-url": null
            }],
            "continuation": null
        }));
    }
    json!({
        "sources": sources,
        "continuation": if initial_only { Some("mock-home-more") } else { None::<&str> }
    })
}

#[cfg(test)]
fn mock_continuation(token: &str, _limit: usize) -> Value {
    if token == "mock-home-more" {
        json!({
            "sources": [{
                "id": "ytm:home:mock:mixed-for-you",
                "kind": "youtube-music-home-section",
                "title": "Mixed for you",
                "url": "ytm://home/mock",
                "items": [{
                    "type": "playlist",
                    "id": "mock-mix",
                    "title": "Mock Mix",
                    "url": "https://music.youtube.com/playlist?list=mock-mix",
                    "browse-id": "VLmock-mix",
                    "playlist-id": "mock-mix",
                    "subtitle": "Playlist",
                    "thumbnail-url": null
                }],
                "continuation": null
            }],
            "continuation": null
        })
    } else {
        json!({
            "sources": [],
            "continuation": null
        })
    }
}

#[cfg(test)]
fn mock_explore_browse(limit: usize) -> Value {
    let item_limit = limit.clamp(1, 2);
    let mut new_releases = vec![json!({
        "type": "album",
        "id": "mock-explore-album",
        "title": "Mock New Release",
        "url": "https://music.youtube.com/browse/mock-explore-album",
        "browse-id": "mock-explore-album",
        "playlist-id": null,
        "subtitle": "Mock Artist",
        "thumbnail-url": null
    })];
    if item_limit > 1 {
        new_releases.push(json!({
            "type": "playlist",
            "id": "mock-explore-playlist",
            "title": "Mock Trending Playlist",
            "url": "https://music.youtube.com/playlist?list=mock-explore-playlist",
            "browse-id": "VLmock-explore-playlist",
            "playlist-id": "mock-explore-playlist",
            "subtitle": "Playlist",
            "thumbnail-url": null
        }));
    }
    json!({
        "sources": [{
            "id": "ytm:explore:mock:new-releases",
            "kind": "youtube-music-explore-section",
            "title": "New releases",
            "url": "ytm://explore/mock",
            "items": new_releases,
            "continuation": null
        }, {
            "id": "ytm:explore:mock:charts",
            "kind": "youtube-music-explore-section",
            "title": "Charts",
            "url": "ytm://explore/mock",
            "items": [{
                "type": "playlist",
                "id": "mock-chart",
                "title": "Mock Chart",
                "url": "https://music.youtube.com/playlist?list=mock-chart",
                "browse-id": "VLmock-chart",
                "playlist-id": "mock-chart",
                "subtitle": "Playlist",
                "thumbnail-url": null
            }],
            "continuation": null
        }]
    })
}

#[cfg(test)]
fn mock_browse_id(browse_id: &str, limit: usize) -> Value {
    let item_limit = limit.clamp(1, 2);
    let kind = if browse_id.starts_with("MPRE") {
        "youtube-music-album"
    } else if browse_id.starts_with("UC") {
        "youtube-music-artist"
    } else if browse_id.starts_with("VL")
        || browse_id.starts_with("PL")
        || browse_id.starts_with("RD")
    {
        "youtube-music-playlist"
    } else {
        "youtube-music-detail"
    };
    let mut items = vec![json!({
        "type": "track",
        "id": "mock-detail-track",
        "title": "Mock Detail Track",
        "url": "https://music.youtube.com/watch?v=mock-detail-track",
        "artist": "Mock Artist",
        "album": "Mock Detail",
        "duration": 181,
        "thumbnail-url": null
    })];
    if item_limit > 1 {
        items.push(json!({
            "type": "track",
            "id": "mock-detail-track-2",
            "title": "Mock Detail Track 2",
            "url": "https://music.youtube.com/watch?v=mock-detail-track-2",
            "artist": "Mock Artist",
            "album": "Mock Detail",
            "duration": 182,
            "thumbnail-url": null
        }));
    }
    json!({
        "sources": [{
            "id": format!("ytm:browse:{browse_id}"),
            "kind": kind,
            "title": format!("Mock {browse_id}"),
            "url": format!("https://music.youtube.com/browse/{browse_id}"),
            "items": items,
            "continuation": null
        }]
    })
}

#[cfg(test)]
mod tests {
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
        let options =
            parse_args(["browse-id", "VLPL1", "--params", "ggMCCAI%3D", "--mock"]).unwrap();
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
        let options =
            parse_args(["auth", "login-window", "--output", "/tmp/ytm/auth.json"]).unwrap();
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
    fn recognizes_top_level_help_requests() {
        assert!(help_requested(&["--help".to_string()]));
        assert!(!help_requested(&[
            "browse".to_string(),
            "--help".to_string()
        ]));
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
    fn error_envelope_classifies_auth_and_network_failures() {
        let auth: Value = serde_json::from_str(&encode_error(
            "YouTube Music returned HTTP 401 Unauthorized",
        ))
        .unwrap();
        assert_eq!(auth["ok"], false);
        assert_eq!(auth["error"]["code"], "auth-required");
        assert_eq!(auth["error"]["auth-required"], true);
        assert_eq!(auth["error"]["retryable"], false);

        let network: Value = serde_json::from_str(&encode_error(
            "YouTube Music browse request failed: error sending request",
        ))
        .unwrap();
        assert_eq!(network["error"]["code"], "network");
        assert_eq!(network["error"]["auth-required"], false);
        assert_eq!(network["error"]["retryable"], true);

        let browser: Value = serde_json::from_str(&encode_error(
            "Zen is already running without WebDriver BiDi on 127.0.0.1:29317",
        ))
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
}
