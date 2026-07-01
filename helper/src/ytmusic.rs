// SPDX-License-Identifier: GPL-3.0-or-later

use crate::auth::AuthConfig;
use crate::error::{HelperError, Result};
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, CONTENT_TYPE, USER_AGENT};
use reqwest::Proxy;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha1::{Digest, Sha1};
use std::collections::HashSet;
use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};
use std::time::{SystemTime, UNIX_EPOCH};

const YTM_ORIGIN: &str = "https://music.youtube.com";
const HOME_CONTINUATION_PAGE_LIMIT: usize = 8;
const BOOTSTRAP_CACHE_SCHEMA_VERSION: u32 = 1;
const BOOTSTRAP_CACHE_TTL_SECS: u64 = 12 * 60 * 60;
const RESPONSE_CACHE_SCHEMA_VERSION: u32 = 1;
const RESPONSE_CACHE_TTL_SECS: u64 = 5 * 60;
const RESPONSE_CACHE_MAX_ENTRIES: usize = 80;
const MUTATION_DETAIL_LIMIT: usize = 100;
const TIMINGS_ENV: &str = "YTM_RADIO_TIMINGS";
const YOUTUBEI_SEND_RETRY_DELAYS_MS: [u64; 2] = [250, 750];

#[derive(Clone, Copy)]
enum SendPolicy {
    Read,
    Mutation,
}

#[derive(Clone, Copy)]
struct RequestPolicy<'a> {
    send: SendPolicy,
    cache_dir: Option<&'a Path>,
    cache_ttl_secs: u64,
}

impl<'a> RequestPolicy<'a> {
    fn read(cache_dir: Option<&'a Path>, cache_ttl_secs: u64) -> Self {
        Self {
            send: SendPolicy::Read,
            cache_dir,
            cache_ttl_secs,
        }
    }

    fn mutation() -> Self {
        Self {
            send: SendPolicy::Mutation,
            cache_dir: None,
            cache_ttl_secs: 0,
        }
    }
}

fn youtube_client(proxy: Option<&str>) -> Result<Client> {
    let proxy = proxy.map(str::trim).filter(|value| !value.is_empty());
    let mut builder = Client::builder().timeout(Duration::from_secs(30));
    if let Some(proxy_url) = proxy {
        builder = builder.proxy(
            Proxy::all(proxy_url).map_err(|_| HelperError::invalid_request("invalid proxy URL"))?,
        );
    }
    builder.build().map_err(|error| {
        HelperError::helper_failure(if proxy.is_some() {
            "cannot create HTTP client with proxy".to_string()
        } else {
            format!("cannot create HTTP client: {error}")
        })
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowseTarget {
    Home,
    Explore,
    Library,
    LibrarySongs,
    LibraryAlbums,
    LibraryArtists,
    LibraryPlaylists,
    Liked,
}

const LIBRARY_TARGETS: [BrowseTarget; 4] = [
    BrowseTarget::LibrarySongs,
    BrowseTarget::LibraryAlbums,
    BrowseTarget::LibraryArtists,
    BrowseTarget::LibraryPlaylists,
];

pub fn browse(
    target: &BrowseTarget,
    limit: usize,
    auth: &AuthConfig,
    initial_only: bool,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response_cache_dir = bootstrap_cache.map(response_cache_dir);
    if matches!(target, BrowseTarget::Library) {
        return browse_library(
            &client,
            auth,
            &bootstrap,
            limit,
            response_cache_dir.as_deref(),
        );
    }
    let response = request_browse(
        &client,
        auth,
        &bootstrap,
        target,
        response_cache_dir.as_deref(),
    )?;
    if matches!(target, BrowseTarget::Home) {
        if initial_only {
            Ok(normalize_sectioned_response(target, limit, &response))
        } else {
            let responses = request_home_continuations(
                &client,
                auth,
                &bootstrap,
                response,
                response_cache_dir.as_deref(),
            )?;
            Ok(normalize_sectioned_responses(target, limit, &responses))
        }
    } else if matches!(target, BrowseTarget::Explore) {
        Ok(normalize_sectioned_response(target, limit, &response))
    } else {
        Ok(normalize_single_source_response(target, limit, &response))
    }
}

pub fn continuation(
    token: &str,
    limit: usize,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_continuation(
        &client,
        auth,
        &bootstrap,
        token,
        bootstrap_cache.map(response_cache_dir).as_deref(),
    )?;
    Ok(normalize_home_continuation_response(
        token, limit, &response,
    ))
}

pub fn browse_id(
    browse_id: &str,
    params: Option<&str>,
    limit: usize,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_browse_id(&client, auth, &bootstrap, browse_id, params, None)?;
    Ok(normalize_browse_id_response(browse_id, limit, &response))
}

pub fn search(
    query: &str,
    limit: usize,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_search(&client, auth, &bootstrap, query, None)?;
    Ok(normalize_search_response(query, limit, &response))
}

pub fn rate(
    video_id: &str,
    rating: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let endpoint = match rating {
        "like" => "like/like",
        "dislike" => "like/dislike",
        "indifferent" => "like/removelike",
        other => {
            return Err(HelperError::invalid_request(format!(
                "unknown rating `{other}`"
            )))
        }
    };
    let body = json!({
        "context": youtubei_context(auth, &bootstrap),
        "target": { "videoId": video_id }
    });
    request_youtubei_path(
        &client,
        auth,
        &bootstrap,
        endpoint,
        &body,
        RequestPolicy::mutation(),
    )?;
    Ok(json!({
        "video-id": video_id,
        "rating": rating
    }))
}

pub fn radio(
    video_id: &str,
    limit: usize,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_radio_queue(&client, auth, &bootstrap, video_id)?;
    Ok(normalize_radio_response(video_id, limit, &response))
}

pub fn playlist_options(
    video_id: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_add_to_playlist_options(&client, auth, &bootstrap, video_id, None)?;
    Ok(normalize_add_to_playlist_options(&response))
}

pub fn add_to_playlist(
    video_id: &str,
    playlist_id: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let clean_playlist_id = clean_playlist_id(playlist_id);
    let body = json!({
        "context": youtubei_context(auth, &bootstrap),
        "playlistId": clean_playlist_id,
        "actions": [{
            "action": "ACTION_ADD_VIDEO",
            "addedVideoId": video_id
        }]
    });
    request_youtubei_path(
        &client,
        auth,
        &bootstrap,
        "browse/edit_playlist",
        &body,
        RequestPolicy::mutation(),
    )?;
    Ok(json!({
        "video-id": video_id,
        "playlist-id": clean_playlist_id
    }))
}

pub fn library(
    video_id: &str,
    action: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_song_next(&client, auth, &bootstrap, video_id)?;
    let state = song_library_state(&response, video_id)?;
    let (token, target_in_library, normalized_action) = match action {
        "toggle" if state.in_library => (state.remove_token.as_deref(), false, "remove"),
        "toggle" => (state.add_token.as_deref(), true, "save"),
        "save" if state.in_library => (None, true, "save"),
        "save" => (state.add_token.as_deref(), true, "save"),
        "remove" if !state.in_library => (None, false, "remove"),
        "remove" => (state.remove_token.as_deref(), false, "remove"),
        other => {
            return Err(HelperError::invalid_request(format!(
                "unknown library action `{other}`"
            )))
        }
    };
    if let Some(token) = token {
        apply_feedback_token(&client, auth, &bootstrap, token)?;
        Ok(track_account_output(
            video_id,
            target_in_library,
            &state,
            Some(normalized_action),
            Some(true),
        ))
    } else if state.in_library == target_in_library {
        Ok(track_account_output(
            video_id,
            target_in_library,
            &state,
            Some(normalized_action),
            Some(false),
        ))
    } else {
        Err(format!(
            "YouTube Music did not return a {normalized_action} library token for `{video_id}`"
        )
        .into())
    }
}

pub fn item_library(
    browse_id: &str,
    params: Option<&str>,
    action: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_browse_id(&client, auth, &bootstrap, browse_id, params, None)?;
    let state = browse_header_state(&response);
    let playlist_id = item_library_playlist_id(browse_id, &response);
    let (token, target_in_library, normalized_action) = match action {
        "toggle" if state.in_library => (state.remove_token.as_deref(), false, "remove"),
        "toggle" => (state.add_token.as_deref(), true, "save"),
        "save" if state.in_library => (None, true, "save"),
        "save" => (state.add_token.as_deref(), true, "save"),
        "remove" if state.library_known && !state.in_library => (None, false, "remove"),
        "remove" => (state.remove_token.as_deref(), false, "remove"),
        other => {
            return Err(HelperError::invalid_request(format!(
                "unknown library action `{other}`"
            )))
        }
    };
    let changed = if let Some(token) = token {
        apply_feedback_token(&client, auth, &bootstrap, token)?;
        true
    } else if state.library_known && state.in_library == target_in_library {
        false
    } else if let Some(playlist_id) = playlist_id.as_deref() {
        apply_playlist_library_rating(&client, auth, &bootstrap, playlist_id, target_in_library)?;
        true
    } else {
        return Err(format!(
            "YouTube Music did not return a {normalized_action} library token or playlist id for `{browse_id}`"
        )
        .into());
    };
    Ok(detail_mutation_output(
        browse_id,
        &response,
        normalized_action,
        changed,
        Some(target_in_library),
        None,
    ))
}

pub fn subscription(
    browse_id: &str,
    params: Option<&str>,
    action: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_browse_id(&client, auth, &bootstrap, browse_id, params, None)?;
    let state = browse_header_state(&response);
    let (endpoint, target_subscribed, normalized_action) = match action {
        "toggle" if state.subscribed == Some(true) => {
            (state.unsubscribe_endpoint.as_ref(), false, "unsubscribe")
        }
        "toggle" if state.subscribed == Some(false) => {
            (state.subscribe_endpoint.as_ref(), true, "subscribe")
        }
        "toggle" => {
            return Err(format!(
                "YouTube Music did not return subscription state for `{browse_id}`"
            )
            .into())
        }
        "subscribe" if state.subscribed == Some(true) => (None, true, "subscribe"),
        "subscribe" => (state.subscribe_endpoint.as_ref(), true, "subscribe"),
        "unsubscribe" if state.subscribed == Some(false) => (None, false, "unsubscribe"),
        "unsubscribe" => (state.unsubscribe_endpoint.as_ref(), false, "unsubscribe"),
        other => {
            return Err(HelperError::invalid_request(format!(
                "unknown subscription action `{other}`"
            )))
        }
    };
    if state.subscribed == Some(target_subscribed) {
        return Ok(detail_mutation_output(
            browse_id,
            &response,
            normalized_action,
            false,
            None,
            Some(target_subscribed),
        ));
    }
    let fallback_endpoint;
    let endpoint = if let Some(endpoint) = endpoint {
        endpoint
    } else {
        fallback_endpoint = channel_subscription_endpoint(browse_id).ok_or_else(|| {
            format!("YouTube Music did not return a {normalized_action} endpoint for `{browse_id}`")
        })?;
        &fallback_endpoint
    };
    request_subscription_endpoint(&client, auth, &bootstrap, normalized_action, endpoint)?;
    Ok(detail_mutation_output(
        browse_id,
        &response,
        normalized_action,
        true,
        None,
        Some(target_subscribed),
    ))
}

fn apply_feedback_token(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    token: &str,
) -> Result<()> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "feedbackTokens": [token]
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "feedback",
        &body,
        RequestPolicy::mutation(),
    )?;
    Ok(())
}

fn apply_playlist_library_rating(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    playlist_id: &str,
    in_library: bool,
) -> Result<()> {
    let path = if in_library {
        "like/like"
    } else {
        "like/removelike"
    };
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "target": { "playlistId": clean_playlist_id(playlist_id) }
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        path,
        &body,
        RequestPolicy::mutation(),
    )?;
    Ok(())
}

pub fn track_status(
    video_id: &str,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
    proxy: Option<&str>,
) -> Result<Value> {
    let client = youtube_client(proxy)?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_song_next(&client, auth, &bootstrap, video_id)?;
    let state = song_library_state(&response, video_id)?;
    Ok(track_account_output(
        video_id,
        state.in_library,
        &state,
        None,
        None,
    ))
}

fn track_account_output(
    video_id: &str,
    in_library: bool,
    state: &MenuState,
    action: Option<&str>,
    changed: Option<bool>,
) -> Value {
    let mut object = Map::from_iter([
        ("video-id".to_string(), Value::String(video_id.to_string())),
        ("in-library".to_string(), Value::Bool(in_library)),
    ]);
    insert_like_status(&mut object, state);
    if let Some(action) = action {
        object.insert("action".to_string(), Value::String(action.to_string()));
    }
    if let Some(changed) = changed {
        object.insert("changed".to_string(), Value::Bool(changed));
    }
    Value::Object(object)
}

#[derive(Clone, Debug)]
struct Bootstrap {
    api_key: String,
    client_version: String,
    visitor_data: Option<String>,
    context: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
struct BootstrapCache {
    schema: u32,
    fetched_at: u64,
    api_key: String,
    client_version: String,
    visitor_data: Option<String>,
    context: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ResponseCache {
    schema: u32,
    fetched_at: u64,
    ttl_secs: u64,
    value: Value,
}

impl From<BootstrapCache> for Bootstrap {
    fn from(cache: BootstrapCache) -> Self {
        Self {
            api_key: cache.api_key,
            client_version: cache.client_version,
            visitor_data: cache.visitor_data,
            context: cache.context,
        }
    }
}

pub fn bootstrap_cache_path(auth_path: &Path) -> PathBuf {
    auth_path.with_file_name("bootstrap-cache.json")
}

pub fn clear_response_cache(bootstrap_cache_path: &Path) -> Result<()> {
    let cache_dir = response_cache_dir(bootstrap_cache_path);
    match fs::remove_dir_all(&cache_dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "cannot clear response cache `{}`: {error}",
            cache_dir.display()
        )
        .into()),
    }
}

pub fn clear_account_cache(bootstrap_cache_path: &Path) -> Result<()> {
    clear_response_cache(bootstrap_cache_path)?;
    match fs::remove_file(bootstrap_cache_path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "cannot clear bootstrap cache `{}`: {error}",
            bootstrap_cache_path.display()
        )
        .into()),
    }
}

fn bootstrap_with_cache(
    client: &Client,
    auth: &AuthConfig,
    cache_path: Option<&Path>,
) -> Result<Bootstrap> {
    let Some(cache_path) = cache_path else {
        let started = Instant::now();
        let bootstrap = bootstrap(client, auth)?;
        log_timing("bootstrap-network", started);
        return Ok(bootstrap);
    };

    let cache_started = Instant::now();
    if let Some(cached) = load_bootstrap_cache(cache_path) {
        log_diagnostic("bootstrap-cache=hit");
        log_timing("bootstrap-cache-read", cache_started);
        return Ok(cached);
    }
    log_diagnostic("bootstrap-cache=miss");

    let started = Instant::now();
    let bootstrap = bootstrap(client, auth)?;
    log_timing("bootstrap-network", started);
    if let Err(error) = save_bootstrap_cache(cache_path, &bootstrap) {
        log_diagnostic(&format!("bootstrap-cache-write-error={error}"));
    }
    Ok(bootstrap)
}

fn load_bootstrap_cache(path: &Path) -> Option<Bootstrap> {
    let content = fs::read_to_string(path).ok()?;
    let cache: BootstrapCache = serde_json::from_str(&content).ok()?;
    if cache.schema != BOOTSTRAP_CACHE_SCHEMA_VERSION {
        return None;
    }
    let now = current_timestamp().ok()?;
    if cache.fetched_at > now || now.saturating_sub(cache.fetched_at) > BOOTSTRAP_CACHE_TTL_SECS {
        return None;
    }
    Some(cache.into())
}

fn save_bootstrap_cache(path: &Path, bootstrap: &Bootstrap) -> Result<()> {
    let cache = BootstrapCache {
        schema: BOOTSTRAP_CACHE_SCHEMA_VERSION,
        fetched_at: current_timestamp()?,
        api_key: bootstrap.api_key.clone(),
        client_version: bootstrap.client_version.clone(),
        visitor_data: bootstrap.visitor_data.clone(),
        context: bootstrap.context.clone(),
    };
    let content = serde_json::to_vec_pretty(&cache)
        .map_err(|error| format!("cannot encode bootstrap cache: {error}"))?;
    write_private_bytes(path, &content)
}

fn response_cache_dir(bootstrap_cache_path: &Path) -> PathBuf {
    bootstrap_cache_path.with_file_name("response-cache")
}

fn response_cache_key(
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    path: &str,
    body: &Value,
) -> Result<String> {
    let mut hasher = Sha1::new();
    hasher.update(path.as_bytes());
    hasher.update([0]);
    hasher.update(bootstrap.client_version.as_bytes());
    hasher.update([0]);
    if let Some(cookie) = auth.header("cookie") {
        hasher.update(cookie.as_bytes());
    }
    hasher.update([0]);
    if let Some(auth_user) = auth.header("x-goog-authuser") {
        hasher.update(auth_user.as_bytes());
    }
    hasher.update([0]);
    if let Some(page_id) = auth.header("x-goog-pageid") {
        hasher.update(page_id.as_bytes());
    }
    hasher.update([0]);
    let body_bytes =
        serde_json::to_vec(body).map_err(|error| format!("cannot encode cache key: {error}"))?;
    hasher.update(body_bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

fn response_cache_file(cache_dir: &Path, key: &str) -> PathBuf {
    cache_dir.join(format!("{key}.json"))
}

fn load_response_cache(path: &Path) -> Option<Value> {
    let content = fs::read_to_string(path).ok()?;
    let cache: ResponseCache = serde_json::from_str(&content).ok()?;
    if cache.schema != RESPONSE_CACHE_SCHEMA_VERSION {
        return None;
    }
    let now = current_timestamp().ok()?;
    if cache.fetched_at > now || now.saturating_sub(cache.fetched_at) > cache.ttl_secs {
        return None;
    }
    Some(cache.value)
}

fn save_response_cache(path: &Path, value: &Value, ttl_secs: u64) -> Result<()> {
    let cache = ResponseCache {
        schema: RESPONSE_CACHE_SCHEMA_VERSION,
        fetched_at: current_timestamp()?,
        ttl_secs,
        value: value.clone(),
    };
    let content = serde_json::to_vec(&cache)
        .map_err(|error| format!("cannot encode response cache: {error}"))?;
    write_private_bytes(path, &content)
}

fn prune_response_cache(cache_dir: &Path) {
    let Ok(entries) = fs::read_dir(cache_dir) else {
        return;
    };
    let mut files = entries
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                return None;
            }
            let modified = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .unwrap_or(UNIX_EPOCH);
            Some((path, modified))
        })
        .collect::<Vec<_>>();
    if files.len() <= RESPONSE_CACHE_MAX_ENTRIES {
        return;
    }
    files.sort_by_key(|(_, modified)| *modified);
    let remove_count = files.len() - RESPONSE_CACHE_MAX_ENTRIES;
    for (path, _) in files.into_iter().take(remove_count) {
        let _ = fs::remove_file(path);
    }
}

fn write_private_bytes(path: &Path, content: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create `{}`: {error}", parent.display()))?;
    }
    write_private_file(path, content)
}

#[cfg(unix)]
fn write_private_file(path: &Path, content: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("cannot write `{}`: {error}", path.display()))?;
    file.write_all(content)
        .map_err(|error| format!("cannot write `{}`: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        HelperError::helper_failure(format!(
            "cannot set permissions on `{}`: {error}",
            path.display()
        ))
    })
}

#[cfg(not(unix))]
fn write_private_file(path: &Path, content: &[u8]) -> Result<()> {
    fs::write(path, content).map_err(|error| {
        HelperError::helper_failure(format!("cannot write `{}`: {error}", path.display()))
    })
}

fn bootstrap(client: &Client, auth: &AuthConfig) -> Result<Bootstrap> {
    let response = client
        .get(YTM_ORIGIN)
        .headers(base_headers(auth)?)
        .send()
        .map_err(|error| HelperError::network(format!("cannot load YouTube Music: {error}")))?;
    let status = response.status();
    let html = response.text().map_err(|error| {
        HelperError::network(format!("cannot read YouTube Music bootstrap: {error}"))
    })?;
    if !status.is_success() {
        let message = format!("YouTube Music bootstrap returned HTTP {status}");
        return Err(if matches!(status.as_u16(), 401 | 403) {
            HelperError::auth_required(message)
        } else if status.as_u16() == 429 || status.is_server_error() {
            HelperError::remote_response(message)
        } else {
            HelperError::helper_failure(message)
        });
    }
    Ok(Bootstrap {
        api_key: extract_config_string(&html, "INNERTUBE_API_KEY")
            .ok_or_else(|| "YouTube Music bootstrap did not contain an API key".to_string())?,
        client_version: extract_config_string(&html, "INNERTUBE_CLIENT_VERSION").ok_or_else(
            || "YouTube Music bootstrap did not contain a client version".to_string(),
        )?,
        visitor_data: extract_config_string(&html, "VISITOR_DATA"),
        context: extract_config_value(&html, "INNERTUBE_CONTEXT"),
    })
}

fn request_browse(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    target: &BrowseTarget,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    let (browse_id, params) = match target {
        BrowseTarget::Home => ("FEmusic_home", None),
        BrowseTarget::Explore => ("FEmusic_explore", None),
        BrowseTarget::Library => ("FEmusic_library_landing", None),
        BrowseTarget::LibrarySongs => ("FEmusic_liked_videos", None),
        BrowseTarget::LibraryAlbums => ("FEmusic_liked_albums", None),
        BrowseTarget::LibraryArtists => ("FEmusic_library_corpus_artists", Some("ggMCCAU=")),
        BrowseTarget::LibraryPlaylists => ("FEmusic_liked_playlists", None),
        BrowseTarget::Liked => ("VLLM", None),
    };
    request_browse_id_with_ttl(
        client,
        auth,
        bootstrap,
        browse_id,
        params,
        cache_dir,
        RESPONSE_CACHE_TTL_SECS,
    )
}

fn request_browse_id(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    browse_id: &str,
    params: Option<&str>,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    request_browse_id_with_ttl(
        client,
        auth,
        bootstrap,
        browse_id,
        params,
        cache_dir,
        RESPONSE_CACHE_TTL_SECS,
    )
}

fn request_browse_id_with_ttl(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    browse_id: &str,
    params: Option<&str>,
    cache_dir: Option<&Path>,
    ttl_secs: u64,
) -> Result<Value> {
    let body = browse_id_request_body(auth, bootstrap, browse_id, params);
    request_youtubei(client, auth, bootstrap, &body, cache_dir, ttl_secs)
}

fn browse_id_request_body(
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    browse_id: &str,
    params: Option<&str>,
) -> Value {
    let mut body = json!({
        "context": youtubei_context(auth, bootstrap),
        "browseId": browse_id
    });
    if let Some(params) = params.filter(|value| !value.trim().is_empty()) {
        if let Some(object) = body.as_object_mut() {
            object.insert("params".to_string(), Value::String(params.to_string()));
        }
    }
    body
}

fn youtubei_context(auth: &AuthConfig, bootstrap: &Bootstrap) -> Value {
    let auth_context = auth
        .innertube_context
        .as_ref()
        .filter(|value| value.is_object());
    let mut context = bootstrap
        .context
        .clone()
        .filter(Value::is_object)
        .or_else(|| auth_context.cloned())
        .unwrap_or_else(|| json!({}));
    if let Some(auth_context) = auth_context {
        merge_auth_context_identity(&mut context, auth_context);
    }
    let object = context.as_object_mut().expect("context is an object");
    if !object.get("client").map(Value::is_object).unwrap_or(false) {
        object.insert("client".to_string(), Value::Object(Map::new()));
    }
    {
        let client = object
            .get_mut("client")
            .and_then(Value::as_object_mut)
            .expect("client is an object");
        client
            .entry("clientName".to_string())
            .or_insert_with(|| Value::String("WEB_REMIX".to_string()));
        client.insert(
            "clientVersion".to_string(),
            Value::String(bootstrap.client_version.clone()),
        );
        client
            .entry("hl".to_string())
            .or_insert_with(|| Value::String("en".to_string()));
    }
    if !object.get("user").map(Value::is_object).unwrap_or(false) {
        object.insert("user".to_string(), Value::Object(Map::new()));
    }
    if let Some(page_id) = auth
        .header("x-goog-pageid")
        .filter(|value| !value.trim().is_empty())
    {
        let user = object
            .get_mut("user")
            .and_then(Value::as_object_mut)
            .expect("user is an object");
        user.entry("onBehalfOfUser".to_string())
            .or_insert_with(|| Value::String(page_id.to_string()));
    }
    {
        let user = object
            .get_mut("user")
            .and_then(Value::as_object_mut)
            .expect("user is an object");
        user.entry("lockedSafetyMode".to_string())
            .or_insert(Value::Bool(false));
    }
    context
}

fn merge_auth_context_identity(context: &mut Value, auth_context: &Value) {
    let Some(on_behalf_of_user) = auth_context
        .pointer("/user/onBehalfOfUser")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        return;
    };
    let Some(user) = context_user_object(context) else {
        return;
    };
    user.entry("onBehalfOfUser".to_string())
        .or_insert_with(|| Value::String(on_behalf_of_user.to_string()));
}

fn context_user_object(context: &mut Value) -> Option<&mut Map<String, Value>> {
    let context = context.as_object_mut()?;
    if !context.get("user").map(Value::is_object).unwrap_or(false) {
        context.insert("user".to_string(), Value::Object(Map::new()));
    }
    context.get_mut("user").and_then(Value::as_object_mut)
}

fn browse_library(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    limit: usize,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    let normalized_sections = thread::scope(|scope| {
        let handles = LIBRARY_TARGETS
            .into_iter()
            .map(|target| {
                let client = client.clone();
                scope.spawn(move || {
                    let response = request_browse(&client, auth, bootstrap, &target, cache_dir)?;
                    Ok::<Value, HelperError>(normalize_single_source_response(
                        &target, limit, &response,
                    ))
                })
            })
            .collect::<Vec<_>>();

        let mut sections = Vec::with_capacity(handles.len());
        for handle in handles {
            sections.push(handle.join().map_err(|_| {
                HelperError::helper_failure("YouTube Music library request thread panicked")
            })??);
        }
        Ok::<Vec<Value>, HelperError>(sections)
    })?;

    let mut sources = Vec::new();
    for normalized in normalized_sections {
        if let Some(items) = normalized.get("sources").and_then(Value::as_array) {
            sources.extend(items.iter().cloned());
        }
    }
    Ok(json!({ "sources": sources }))
}

fn request_search(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    query: &str,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "query": query
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "search",
        &body,
        RequestPolicy::read(cache_dir, RESPONSE_CACHE_TTL_SECS),
    )
}

fn request_song_next(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    video_id: &str,
) -> Result<Value> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "videoId": video_id,
        "enablePersistentPlaylistPanel": true,
        "isAudioOnly": true,
        "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "next",
        &body,
        RequestPolicy::read(None, 0),
    )
}

fn request_radio_queue(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    video_id: &str,
) -> Result<Value> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "videoId": video_id,
        "playlistId": format!("RDAMVM{video_id}"),
        "enablePersistentPlaylistPanel": true,
        "isAudioOnly": true,
        "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "next",
        &body,
        RequestPolicy::read(None, 0),
    )
}

fn request_add_to_playlist_options(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    video_id: &str,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "videoIds": [video_id]
    });
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "playlist/get_add_to_playlist",
        &body,
        RequestPolicy::read(cache_dir, RESPONSE_CACHE_TTL_SECS),
    )
}

fn request_continuation(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    continuation: &str,
    cache_dir: Option<&Path>,
) -> Result<Value> {
    let body = json!({
        "context": youtubei_context(auth, bootstrap),
        "continuation": continuation
    });
    request_youtubei(
        client,
        auth,
        bootstrap,
        &body,
        cache_dir,
        RESPONSE_CACHE_TTL_SECS,
    )
}

fn request_youtubei(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    body: &Value,
    cache_dir: Option<&Path>,
    ttl_secs: u64,
) -> Result<Value> {
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        "browse",
        body,
        RequestPolicy::read(cache_dir, ttl_secs),
    )
}

fn request_youtubei_path(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    path: &str,
    body: &Value,
    policy: RequestPolicy<'_>,
) -> Result<Value> {
    let cache_file = policy
        .cache_dir
        .map(|cache_dir| {
            response_cache_key(auth, bootstrap, path, body)
                .map(|key| response_cache_file(cache_dir, &key))
        })
        .transpose()?;
    if let Some(cache_file) = &cache_file {
        let started = Instant::now();
        if let Some(value) = load_response_cache(cache_file) {
            log_diagnostic(&format!("response-cache=hit path={path}"));
            log_timing(&format!("response-cache-read-{path}"), started);
            return Ok(value);
        }
        log_diagnostic(&format!("response-cache=miss path={path}"));
    }
    let mut headers = base_headers(auth)?;
    insert_header(
        &mut headers,
        "authorization",
        &authorization_header(auth, current_timestamp()?)?,
    )?;
    insert_header(
        &mut headers,
        "x-youtube-client-version",
        &bootstrap.client_version,
    )?;
    insert_header(&mut headers, "x-youtube-client-name", "67")?;
    if let Some(visitor_data) = &bootstrap.visitor_data {
        insert_header(&mut headers, "x-goog-visitor-id", visitor_data)?;
    }
    let started = Instant::now();
    let url = format!(
        "{YTM_ORIGIN}/youtubei/v1/{path}?alt=json&key={}",
        bootstrap.api_key
    );
    let response = send_youtubei_request(client, &url, headers, body, path, policy.send)
        .map_err(|error| error.context(format!("YouTube Music {path} request failed")))?;
    let status = response.status();
    let response_body = response.text().map_err(|error| {
        HelperError::network(format!("cannot read YouTube Music response: {error}"))
    })?;
    log_timing(&format!("youtubei-{path}"), started);
    if !status.is_success() {
        let message = serde_json::from_str::<Value>(&response_body)
            .ok()
            .and_then(|value| {
                value
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| "request rejected".to_string());
        let message = format!("YouTube Music returned HTTP {status}: {message}");
        return Err(if matches!(status.as_u16(), 401 | 403) {
            HelperError::auth_required(message)
        } else if status.as_u16() == 429 || status.is_server_error() {
            HelperError::remote_response(message)
        } else {
            HelperError::helper_failure(message)
        });
    }
    let value = serde_json::from_str(&response_body)
        .map_err(|error| format!("invalid YouTube Music response: {error}"))?;
    if let Some(cache_file) = &cache_file {
        if let Err(error) = save_response_cache(cache_file, &value, policy.cache_ttl_secs) {
            log_diagnostic(&format!("response-cache-write-error={error}"));
        } else if let Some(cache_dir) = cache_file.parent() {
            prune_response_cache(cache_dir);
        }
    }
    Ok(value)
}

fn send_youtubei_request(
    client: &Client,
    url: &str,
    headers: HeaderMap,
    body: &Value,
    path: &str,
    send_policy: SendPolicy,
) -> Result<reqwest::blocking::Response> {
    send_operation(
        send_policy,
        || client.post(url).headers(headers.clone()).json(body).send(),
        |attempt, delay, error| {
            log_diagnostic(&format!(
                "youtubei-send-retry path={path} attempt={attempt} delay_ms={} error={error}",
                delay.as_millis()
            ));
            thread::sleep(delay);
        },
    )
}

fn send_operation<T, E, F, R>(policy: SendPolicy, mut operation: F, retry: R) -> Result<T>
where
    E: Error + 'static,
    F: FnMut() -> std::result::Result<T, E>,
    R: FnMut(usize, Duration, &str),
{
    match policy {
        SendPolicy::Read => retry_send_operation(operation, retry),
        SendPolicy::Mutation => {
            operation().map_err(|error| HelperError::network(error_chain_message(&error)))
        }
    }
}

fn retry_send_operation<T, E, F, R>(mut operation: F, mut retry: R) -> Result<T>
where
    E: Error + 'static,
    F: FnMut() -> std::result::Result<T, E>,
    R: FnMut(usize, Duration, &str),
{
    let mut attempt = 1;
    loop {
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) => {
                let message = error_chain_message(&error);
                if attempt > YOUTUBEI_SEND_RETRY_DELAYS_MS.len() {
                    return Err(HelperError::network(if attempt == 1 {
                        message
                    } else {
                        format!("{message} after {attempt} attempts")
                    }));
                }
                let delay = Duration::from_millis(YOUTUBEI_SEND_RETRY_DELAYS_MS[attempt - 1]);
                retry(attempt, delay, &message);
                attempt += 1;
            }
        }
    }
}

fn error_chain_message(error: &(dyn Error + 'static)) -> String {
    let mut messages = vec![error.to_string()];
    let mut source = error.source();
    while let Some(error) = source {
        let message = error.to_string();
        if !messages.iter().any(|existing| existing == &message) {
            messages.push(message);
        }
        source = error.source();
    }
    messages.join(": ")
}

fn request_home_continuations(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    first_response: Value,
    cache_dir: Option<&Path>,
) -> Result<Vec<Value>> {
    let mut responses = vec![first_response];
    let mut seen_tokens = HashSet::new();
    for _ in 0..HOME_CONTINUATION_PAGE_LIMIT {
        let Some(token) = responses.last().and_then(find_home_continuation) else {
            break;
        };
        if !seen_tokens.insert(token.clone()) {
            break;
        }
        responses.push(request_continuation(
            client, auth, bootstrap, &token, cache_dir,
        )?);
    }
    Ok(responses)
}

fn find_home_continuation(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            for renderer_name in ["sectionListRenderer", "sectionListContinuation"] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(continuation) = find_section_list_continuation(renderer) {
                        return Some(continuation);
                    }
                }
            }
            if let Some(items) = object
                .get("appendContinuationItemsAction")
                .and_then(|action| action.get("continuationItems"))
                .and_then(Value::as_array)
            {
                if let Some(continuation) = find_continuation_item_token(items) {
                    return Some(continuation);
                }
            }
            object.values().find_map(find_home_continuation)
        }
        Value::Array(array) => array.iter().find_map(find_home_continuation),
        _ => None,
    }
}

fn find_section_list_continuation(renderer: &Value) -> Option<String> {
    find_direct_continuation(renderer).or_else(|| {
        renderer
            .get("contents")
            .and_then(Value::as_array)
            .and_then(|items| find_continuation_item_token(items))
    })
}

fn find_continuation_item_token(items: &[Value]) -> Option<String> {
    items.iter().find_map(|item| {
        item.get("continuationItemRenderer")
            .and_then(find_direct_continuation)
    })
}

fn find_direct_continuation(value: &Value) -> Option<String> {
    [
        "/continuations/0/nextContinuationData/continuation",
        "/continuations/0/reloadContinuationData/continuation",
        "/continuations/0/timedContinuationData/continuation",
        "/continuationEndpoint/continuationCommand/token",
        "/endpoint/continuationCommand/token",
        "/button/buttonRenderer/navigationEndpoint/continuationCommand/token",
    ]
    .iter()
    .find_map(|pointer| {
        value
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_string)
    })
}

fn base_headers(auth: &AuthConfig) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let origin = auth.header("origin").unwrap_or(YTM_ORIGIN);
    insert_header(&mut headers, "origin", origin)?;
    insert_header(
        &mut headers,
        "referer",
        auth.header("referer").unwrap_or(YTM_ORIGIN),
    )?;
    insert_header(
        &mut headers,
        "x-origin",
        auth.header("x-origin").unwrap_or(origin),
    )?;
    let cookie = auth
        .header("cookie")
        .ok_or_else(|| HelperError::auth_required("auth file is missing cookie header"))?;
    insert_header(
        &mut headers,
        "cookie",
        &cookie_header_with_consent(cookie, auth.cookie("SOCS").is_some()),
    )?;
    insert_header(
        &mut headers,
        "x-goog-authuser",
        auth.header("x-goog-authuser").unwrap_or("0"),
    )?;
    let user_agent = auth.header("user-agent").unwrap_or("ytm-radio-helper/0.1");
    headers.insert(
        USER_AGENT,
        HeaderValue::from_str(user_agent)
            .map_err(|error| format!("invalid user-agent header: {error}"))?,
    );
    Ok(headers)
}

fn cookie_header_with_consent(cookie: &str, has_consent_cookie: bool) -> String {
    if has_consent_cookie {
        cookie.to_string()
    } else if cookie.trim().is_empty() {
        "SOCS=CAI".to_string()
    } else {
        format!("{cookie}; SOCS=CAI")
    }
}

fn insert_header(headers: &mut HeaderMap, name: &str, value: &str) -> Result<()> {
    let name = HeaderName::from_bytes(name.as_bytes())
        .map_err(|error| format!("invalid header name `{name}`: {error}"))?;
    let value = HeaderValue::from_str(value)
        .map_err(|error| format!("invalid value for header `{name}`: {error}"))?;
    headers.insert(name, value);
    Ok(())
}

fn authorization_header(auth: &AuthConfig, timestamp: u64) -> Result<String> {
    let sapisid = auth
        .cookie("__Secure-3PAPISID")
        .or_else(|| auth.cookie("SAPISID"))
        .ok_or_else(|| HelperError::auth_required("auth cookie is missing SAPISID"))?;
    let input = format!("{timestamp} {sapisid} {YTM_ORIGIN}");
    let digest = Sha1::digest(input.as_bytes());
    Ok(format!("SAPISIDHASH {timestamp}_{digest:x}"))
}

fn current_timestamp() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| HelperError::helper_failure(format!("system clock error: {error}")))
}

fn timings_enabled() -> bool {
    env::var_os(TIMINGS_ENV).is_some()
}

fn log_timing(label: &str, started: Instant) {
    if timings_enabled() {
        eprintln!(
            "ytm-radio-helper timing {label}={}ms",
            started.elapsed().as_millis()
        );
    }
}

fn log_diagnostic(message: &str) {
    if timings_enabled() {
        eprintln!("ytm-radio-helper {message}");
    }
}

fn extract_config_string(html: &str, key: &str) -> Option<String> {
    extract_config_value(html, key)?
        .as_str()
        .map(str::to_string)
}

fn extract_config_value(html: &str, key: &str) -> Option<Value> {
    let marker = format!("\"{key}\":");
    let start = html.find(&marker)? + marker.len();
    let remaining = html[start..].trim_start();
    let end = json_value_end(remaining)?;
    serde_json::from_str(&remaining[..end]).ok()
}

fn json_value_end(input: &str) -> Option<usize> {
    match input.chars().next()? {
        '"' => json_string_end(input),
        '{' | '[' => json_compound_end(input),
        _ => None,
    }
}

fn json_string_end(input: &str) -> Option<usize> {
    if !input.starts_with('"') {
        return None;
    }
    let mut escaped = false;
    for (index, character) in input.char_indices().skip(1) {
        match character {
            '"' if !escaped => return Some(index + character.len_utf8()),
            '\\' if !escaped => escaped = true,
            _ => escaped = false,
        }
    }
    None
}

fn json_compound_end(input: &str) -> Option<usize> {
    let mut depth = 0_i32;
    let mut in_string = false;
    let mut escaped = false;
    for (index, character) in input.char_indices() {
        if in_string {
            match character {
                '"' if !escaped => in_string = false,
                '\\' if !escaped => {
                    escaped = true;
                    continue;
                }
                _ => {}
            }
            escaped = false;
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' | '[' => depth += 1,
            '}' | ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(index + character.len_utf8());
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
fn normalize_response(target: &BrowseTarget, limit: usize, response: &Value) -> Value {
    if matches!(
        target,
        BrowseTarget::Home | BrowseTarget::Explore | BrowseTarget::Library
    ) {
        return normalize_sectioned_response(target, limit, response);
    }
    normalize_single_source_response(target, limit, response)
}

#[cfg(test)]
fn normalize_home_responses(limit: usize, responses: &[Value]) -> Value {
    normalize_sectioned_responses(&BrowseTarget::Home, limit, responses)
}

fn normalize_sectioned_response(target: &BrowseTarget, limit: usize, response: &Value) -> Value {
    normalize_sectioned_responses_with_parent(target, limit, std::slice::from_ref(response), None)
}

fn normalize_sectioned_responses(
    target: &BrowseTarget,
    limit: usize,
    responses: &[Value],
) -> Value {
    normalize_sectioned_responses_with_parent(target, limit, responses, None)
}

fn normalize_home_continuation_response(token: &str, limit: usize, response: &Value) -> Value {
    let parent_id = format!("ytm:home:more:{}", short_hash(token));
    normalize_sectioned_responses_with_parent(
        &BrowseTarget::Home,
        limit,
        std::slice::from_ref(response),
        Some(&parent_id),
    )
}

fn normalize_sectioned_responses_with_parent(
    target: &BrowseTarget,
    limit: usize,
    responses: &[Value],
    parent_id_override: Option<&str>,
) -> Value {
    let (parent_id, section_kind, fallback_kind, fallback_title, url) =
        sectioned_source_metadata(target);
    let parent_id = parent_id_override.unwrap_or(parent_id);
    let mut sections = Vec::new();
    for response in responses {
        collect_browse_sections(response, &mut sections, limit);
    }
    let sources: Vec<Value> = if sections.is_empty() {
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        for response in responses {
            collect_browse_items(response, &mut items, &mut seen, limit);
        }
        vec![normalized_source(
            parent_id.to_string(),
            fallback_kind,
            fallback_title.to_string(),
            url,
            items,
            responses.last().and_then(find_home_continuation),
        )]
    } else {
        sections
            .into_iter()
            .enumerate()
            .map(|(index, section)| {
                normalized_source(
                    section_id(parent_id, &section.title, index + 1),
                    section_kind,
                    section.title,
                    url,
                    section.items,
                    section.continuation,
                )
            })
            .collect()
    };
    let continuation = if matches!(target, BrowseTarget::Home) {
        responses.last().and_then(find_home_continuation)
    } else {
        None
    };
    json!({
        "sources": sources,
        "continuation": continuation
    })
}

fn sectioned_source_metadata(
    target: &BrowseTarget,
) -> (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
) {
    match target {
        BrowseTarget::Explore => (
            "ytm:explore",
            "youtube-music-explore-section",
            "youtube-music-explore",
            "Explore",
            "https://music.youtube.com/explore",
        ),
        BrowseTarget::Library => (
            "ytm:library",
            "youtube-music-library-section",
            "youtube-music-library",
            "Library",
            "https://music.youtube.com/library",
        ),
        _ => (
            "ytm:home",
            "youtube-music-home-section",
            "youtube-music-home",
            "YouTube Music Home",
            "https://music.youtube.com/",
        ),
    }
}

fn normalize_search_response(query: &str, limit: usize, response: &Value) -> Value {
    let parent_id = format!("ytm:search:{}", short_hash(query));
    let url = format!(
        "https://music.youtube.com/search?q={}",
        url_query_encode(query)
    );
    let root = primary_search_section_root(response).unwrap_or(response);
    let mut sections = Vec::new();
    collect_sections(root, &mut sections, limit);
    if !sections.is_empty() {
        append_unsectioned_search_items(root, &mut sections, limit);
        let sources: Vec<Value> = sections
            .into_iter()
            .enumerate()
            .map(|(index, section)| {
                normalized_source(
                    section_id(&parent_id, &section.title, index + 1),
                    "youtube-music-search-section",
                    section.title,
                    &url,
                    section.items,
                    section.continuation,
                )
            })
            .collect();
        return json!({ "sources": sources });
    }

    let mut items = Vec::new();
    let mut seen = HashSet::new();
    collect_items(root, &mut items, &mut seen, limit);
    json!({
        "sources": [normalized_source(
            parent_id,
            "youtube-music-search",
            format!("Search: {query}"),
            &url,
            items,
            find_first_string_for_key(response, "continuation")
        )]
    })
}

fn primary_search_section_root(value: &Value) -> Option<&Value> {
    let tabs = value
        .pointer("/contents/tabbedSearchResultsRenderer/tabs")
        .and_then(Value::as_array)?;
    tabs.iter()
        .filter_map(|tab| tab.get("tabRenderer"))
        .find(|tab| {
            tab.get("selected")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .or_else(|| tabs.iter().filter_map(|tab| tab.get("tabRenderer")).next())
        .and_then(search_tab_section_root)
}

fn search_tab_section_root(tab: &Value) -> Option<&Value> {
    [
        "/content/sectionListRenderer/contents",
        "/content/sectionListRenderer",
    ]
    .iter()
    .find_map(|pointer| tab.pointer(pointer))
}

fn append_unsectioned_search_items(value: &Value, sections: &mut Vec<MusicSection>, limit: usize) {
    let mut seen = HashSet::new();
    for section in sections.iter() {
        for item in &section.items {
            seen.insert(item_dedupe_key(item));
        }
    }
    let mut items = Vec::new();
    collect_items(value, &mut items, &mut seen, limit);
    if !items.is_empty() {
        sections.push(MusicSection {
            title: "Results".to_string(),
            items,
            continuation: find_first_string_for_key(value, "continuation"),
        });
    }
}

fn normalize_browse_id_response(browse_id: &str, limit: usize, response: &Value) -> Value {
    let title = browse_response_title(response)
        .filter(|title| title.trim() != browse_id)
        .unwrap_or_else(|| detail_fallback_title(browse_id).to_string());
    let url = format!("https://music.youtube.com/browse/{browse_id}");
    let kind = detail_source_kind(browse_id);
    let mut sections = Vec::new();
    collect_sections(response, &mut sections, limit);
    if sections.is_empty() {
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        collect_items(response, &mut items, &mut seen, limit);
        let state = browse_header_state(response);
        return json!({
            "sources": [normalized_source_with_metadata(
                format!("ytm:browse:{browse_id}"),
                kind,
                title.clone(),
                &url,
                items,
                SourceMetadata {
                    continuation: find_first_string_for_key(response, "continuation"),
                    subtitle: browse_response_subtitle(response, &title, kind),
                    thumbnail_url: browse_response_thumbnail_url(response),
                    in_library: menu_state_in_library_value(&state),
                    subscribed: state.subscribed,
                    playlist_id: item_library_playlist_id(browse_id, response),
                },
            )]
        });
    }
    let state = browse_header_state(response);
    let mut sources = vec![normalized_source_with_metadata(
        format!("ytm:browse:{browse_id}:header"),
        kind,
        title.clone(),
        &url,
        Vec::new(),
        SourceMetadata {
            continuation: None,
            subtitle: browse_response_subtitle(response, &title, kind),
            thumbnail_url: browse_response_thumbnail_url(response),
            in_library: menu_state_in_library_value(&state),
            subscribed: state.subscribed,
            playlist_id: item_library_playlist_id(browse_id, response),
        },
    )];
    sources.extend(sections.into_iter().enumerate().map(|(index, section)| {
        normalized_source(
            section_id(
                &format!("ytm:browse:{browse_id}"),
                &section.title,
                index + 1,
            ),
            "youtube-music-detail-section",
            section.title,
            &url,
            section.items,
            section.continuation,
        )
    }));
    json!({ "sources": sources })
}

fn normalize_single_source_response(
    target: &BrowseTarget,
    limit: usize,
    response: &Value,
) -> Value {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    collect_items_for_target(target, response, &mut items, &mut seen, limit);
    let (id, kind, title, url) = match target {
        BrowseTarget::Home => (
            "ytm:home",
            "youtube-music-home",
            "YouTube Music Home",
            "https://music.youtube.com/",
        ),
        BrowseTarget::Explore => (
            "ytm:explore",
            "youtube-music-explore",
            "Explore",
            "https://music.youtube.com/explore",
        ),
        BrowseTarget::Library => (
            "ytm:library",
            "youtube-music-library",
            "Library",
            "https://music.youtube.com/library",
        ),
        BrowseTarget::LibrarySongs => (
            "ytm:library:songs",
            "youtube-music-library",
            "Library Songs",
            "https://music.youtube.com/library/songs",
        ),
        BrowseTarget::LibraryAlbums => (
            "ytm:library:albums",
            "youtube-music-library",
            "Library Albums",
            "https://music.youtube.com/library/albums",
        ),
        BrowseTarget::LibraryArtists => (
            "ytm:library:artists",
            "youtube-music-library",
            "Library Artists",
            "https://music.youtube.com/library/artists",
        ),
        BrowseTarget::LibraryPlaylists => (
            "ytm:library:playlists",
            "youtube-music-library",
            "Library Playlists",
            "https://music.youtube.com/library/playlists",
        ),
        BrowseTarget::Liked => (
            "ytm:library:liked",
            "youtube-music-liked",
            "Liked Music",
            "https://music.youtube.com/playlist?list=LM",
        ),
    };
    json!({
        "sources": [normalized_source(
            id.to_string(),
            kind,
            title.to_string(),
            url,
            items,
            find_first_string_for_key(response, "continuation")
        )]
    })
}

fn detail_source_kind(browse_id: &str) -> &'static str {
    match browse_id {
        id if id.starts_with("MPRE") => "youtube-music-album",
        id if id.starts_with("UC") => "youtube-music-artist",
        id if id.starts_with("MPSP") => "youtube-music-podcast",
        id if id.starts_with("MPED") => "youtube-music-episode",
        id if id.starts_with("VL") || id.starts_with("PL") || id.starts_with("RD") => {
            "youtube-music-playlist"
        }
        _ => "youtube-music-detail",
    }
}

fn detail_fallback_title(browse_id: &str) -> &'static str {
    match detail_source_kind(browse_id) {
        "youtube-music-album" => "Album",
        "youtube-music-artist" => "Artist",
        "youtube-music-podcast" => "Podcast",
        "youtube-music-episode" => "Episode",
        "youtube-music-playlist" => "Playlist",
        _ => "Detail",
    }
}

fn normalized_source(
    id: String,
    kind: &str,
    title: String,
    url: &str,
    items: Vec<Value>,
    continuation: Option<String>,
) -> Value {
    normalized_source_with_metadata(
        id,
        kind,
        title,
        url,
        items,
        SourceMetadata {
            continuation,
            ..Default::default()
        },
    )
}

#[derive(Default)]
struct SourceMetadata {
    continuation: Option<String>,
    subtitle: Option<String>,
    thumbnail_url: Option<String>,
    in_library: Value,
    subscribed: Option<bool>,
    playlist_id: Option<String>,
}

fn normalized_source_with_metadata(
    id: String,
    kind: &str,
    title: String,
    url: &str,
    items: Vec<Value>,
    metadata: SourceMetadata,
) -> Value {
    json!({
        "id": id,
        "kind": kind,
        "title": title,
        "url": url,
        "items": items,
        "subtitle": metadata.subtitle,
        "thumbnail-url": metadata.thumbnail_url,
        "in-library": metadata.in_library,
        "subscribed": metadata.subscribed,
        "playlist-id": metadata.playlist_id,
        "continuation": metadata.continuation
    })
}

fn normalize_radio_response(video_id: &str, limit: usize, response: &Value) -> Value {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    collect_playlist_panel_tracks(response, &mut items, &mut seen, limit);
    let title = items
        .first()
        .and_then(|item| item.get("title"))
        .and_then(Value::as_str)
        .filter(|title| !title.trim().is_empty())
        .map(|title| format!("Radio: {title}"))
        .unwrap_or_else(|| format!("Radio: {video_id}"));
    let url = format!("https://music.youtube.com/watch?v={video_id}&list=RDAMVM{video_id}");
    json!({
        "sources": [normalized_source(
            format!("ytm:radio:{video_id}"),
            "youtube-music-radio",
            title,
            &url,
            items,
            find_radio_continuation(response)
        )]
    })
}

fn normalize_add_to_playlist_options(response: &Value) -> Value {
    let root = find_object_named(response, "addToPlaylistRenderer").unwrap_or(response);
    let title = root.get("title").and_then(first_text);
    let mut options = Vec::new();
    let mut seen = HashSet::new();
    collect_add_to_playlist_options(root, &mut options, &mut seen);
    json!({
        "title": title,
        "options": options,
        "can-create-playlist": contains_object_key(root, "createPlaylistEndpoint")
    })
}

fn collect_playlist_panel_tracks(
    value: &Value,
    items: &mut Vec<Value>,
    seen: &mut HashSet<String>,
    limit: usize,
) {
    if items.len() >= limit {
        return;
    }
    match value {
        Value::Object(object) => {
            if let Some(renderer) = object.get("playlistPanelVideoRenderer") {
                if let Some(item) = parse_playlist_panel_track(renderer) {
                    if seen.insert(item_dedupe_key(&item)) {
                        items.push(item);
                    }
                }
                return;
            }
            for nested in object.values() {
                collect_playlist_panel_tracks(nested, items, seen, limit);
                if items.len() >= limit {
                    break;
                }
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_playlist_panel_tracks(nested, items, seen, limit);
                if items.len() >= limit {
                    break;
                }
            }
        }
        _ => {}
    }
}

fn parse_playlist_panel_track(renderer: &Value) -> Option<Value> {
    let video_id = panel_video_id(renderer)?;
    let title = renderer
        .pointer("/title/runs/0/text")
        .and_then(Value::as_str)
        .filter(|title| !title.trim().is_empty())
        .map(str::to_string)
        .or_else(|| first_text(renderer))?;
    let artist = panel_byline_text(renderer);
    let duration = renderer
        .pointer("/lengthText/runs/0/text")
        .and_then(Value::as_str)
        .and_then(parse_duration);
    let thumbnail_url = renderer
        .get("thumbnail")
        .and_then(find_best_thumbnail)
        .or_else(|| find_best_thumbnail(renderer));
    let menu = panel_menu_state(renderer);
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String("track".to_string())),
        ("id".to_string(), Value::String(video_id.clone())),
        ("title".to_string(), Value::String(title)),
        (
            "url".to_string(),
            Value::String(format!("https://music.youtube.com/watch?v={video_id}")),
        ),
        (
            "artist".to_string(),
            artist.map(Value::String).unwrap_or(Value::Null),
        ),
        ("album".to_string(), Value::Null),
        (
            "duration".to_string(),
            duration.map(Value::from).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
        ("in-library".to_string(), Value::Bool(menu.in_library)),
    ]);
    insert_like_status(&mut item, &menu);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn panel_video_id(renderer: &Value) -> Option<String> {
    renderer
        .get("videoId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| {
            renderer
                .get("navigationEndpoint")
                .and_then(watch_endpoint_from_navigation_endpoint)
                .map(|endpoint| endpoint.video_id)
        })
}

fn panel_byline_text(renderer: &Value) -> Option<String> {
    let runs = renderer
        .pointer("/longBylineText/runs")
        .and_then(Value::as_array)?;
    let parts = runs
        .iter()
        .filter_map(|run| run.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty() && !is_separator(text))
        .map(str::to_string)
        .collect::<Vec<_>>();
    (!parts.is_empty()).then(|| parts.join(" "))
}

#[derive(Debug, Clone)]
struct SubscriptionEndpoint {
    channel_ids: Vec<String>,
    params: Option<String>,
}

#[derive(Debug, Default)]
struct MenuState {
    in_library: bool,
    library_known: bool,
    add_token: Option<String>,
    remove_token: Option<String>,
    like_status: Option<String>,
    like_status_known: bool,
    subscribed: Option<bool>,
    subscribe_endpoint: Option<SubscriptionEndpoint>,
    unsubscribe_endpoint: Option<SubscriptionEndpoint>,
}

fn song_library_state(response: &Value, video_id: &str) -> Result<MenuState> {
    let renderer = find_playlist_panel_video_renderer(response, video_id)
        .ok_or_else(|| format!("YouTube Music did not return metadata for `{video_id}`"))?;
    Ok(panel_menu_state(renderer))
}

fn find_playlist_panel_video_renderer<'a>(value: &'a Value, video_id: &str) -> Option<&'a Value> {
    match value {
        Value::Object(object) => {
            if let Some(renderer) = object.get("playlistPanelVideoRenderer") {
                if panel_video_id(renderer).as_deref() == Some(video_id) {
                    return Some(renderer);
                }
            }
            object
                .values()
                .find_map(|nested| find_playlist_panel_video_renderer(nested, video_id))
        }
        Value::Array(array) => array
            .iter()
            .find_map(|nested| find_playlist_panel_video_renderer(nested, video_id)),
        _ => None,
    }
}

fn panel_menu_state(renderer: &Value) -> MenuState {
    let mut state = MenuState::default();
    collect_menu_state(renderer, &mut state);
    let like_status = parse_like_status_state(renderer);
    state.like_status = like_status.status;
    state.like_status_known = like_status.known;
    state
}

fn menu_state_in_library_value(state: &MenuState) -> Value {
    if state.library_known {
        Value::Bool(state.in_library)
    } else {
        Value::Null
    }
}

fn browse_header_state(response: &Value) -> MenuState {
    let mut state = MenuState::default();
    if let Some(header) = find_header_renderer(response) {
        collect_menu_state(header, &mut state);
    }
    state
}

fn collect_menu_state(value: &Value, state: &mut MenuState) {
    match value {
        Value::Object(object) => {
            if let Some(renderer) = object.get("menuServiceItemRenderer") {
                parse_menu_service_item(renderer, state);
            }
            if let Some(renderer) = object.get("toggleMenuServiceItemRenderer") {
                parse_toggle_menu_item(renderer, state);
            }
            if let Some(renderer) = object.get("buttonRenderer") {
                parse_button_renderer(renderer, state);
            }
            if let Some(renderer) = object.get("subscribeButtonRenderer") {
                parse_subscribe_button_renderer(renderer, state);
            }
            if let Some(endpoint) = object
                .get("subscribeEndpoint")
                .and_then(subscription_endpoint_from_value)
            {
                state.subscribe_endpoint.get_or_insert(endpoint);
                state.subscribed.get_or_insert(false);
            }
            if let Some(endpoint) = object
                .get("unsubscribeEndpoint")
                .and_then(subscription_endpoint_from_value)
            {
                state.unsubscribe_endpoint.get_or_insert(endpoint);
                state.subscribed = Some(true);
            }
            if let Some(subscribed) = object.get("isSubscribed").and_then(Value::as_bool) {
                state.subscribed = Some(subscribed);
            }
            for (key, nested) in object {
                if matches!(
                    key.as_str(),
                    "buttonRenderer"
                        | "menuServiceItemRenderer"
                        | "subscribeButtonRenderer"
                        | "toggleMenuServiceItemRenderer"
                ) {
                    continue;
                }
                collect_menu_state(nested, state);
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_menu_state(nested, state);
            }
        }
        _ => {}
    }
}

fn parse_menu_service_item(renderer: &Value, state: &mut MenuState) {
    let icon_type = renderer
        .pointer("/icon/iconType")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let token = extract_feedback_token(renderer, "serviceEndpoint");
    parse_action_text_state(renderer_label(renderer).as_deref(), state);
    parse_subscription_service_endpoint(renderer, "serviceEndpoint", state, true);
    parse_subscription_service_endpoint(renderer, "navigationEndpoint", state, true);
    match icon_type {
        "LIBRARY_ADD" | "BOOKMARK_BORDER" => {
            state.library_known = true;
            state.add_token = token;
        }
        "LIBRARY_REMOVE" | "BOOKMARK" => {
            state.library_known = true;
            state.in_library = true;
            state.remove_token = token;
        }
        _ => {}
    }
}

fn parse_toggle_menu_item(renderer: &Value, state: &mut MenuState) {
    let icon_type = renderer
        .pointer("/defaultIcon/iconType")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let default_token = extract_feedback_token(renderer, "defaultServiceEndpoint");
    let toggled_token = extract_feedback_token(renderer, "toggledServiceEndpoint");
    parse_action_text_state(renderer_label(renderer).as_deref(), state);
    parse_subscription_service_endpoint(renderer, "defaultServiceEndpoint", state, true);
    parse_subscription_service_endpoint(renderer, "toggledServiceEndpoint", state, false);
    match icon_type {
        "LIBRARY_ADD" | "BOOKMARK_BORDER" => {
            state.library_known = true;
            state.add_token = default_token;
            state.remove_token = toggled_token;
        }
        "LIBRARY_REMOVE" | "BOOKMARK" => {
            state.library_known = true;
            state.in_library = true;
            state.remove_token = default_token;
            state.add_token = toggled_token;
        }
        _ => {}
    }
}

fn parse_button_renderer(renderer: &Value, state: &mut MenuState) {
    parse_action_text_state(renderer_label(renderer).as_deref(), state);
    parse_subscription_service_endpoint(renderer, "serviceEndpoint", state, true);
    parse_subscription_service_endpoint(renderer, "navigationEndpoint", state, true);
}

fn parse_subscribe_button_renderer(renderer: &Value, state: &mut MenuState) {
    if let Some(subscribed) = renderer.get("subscribed").and_then(Value::as_bool) {
        state.subscribed = Some(subscribed);
    }
    collect_subscription_endpoints(renderer, state);
}

fn renderer_label(renderer: &Value) -> Option<String> {
    [
        "/text/runs/0/text",
        "/text/simpleText",
        "/title/runs/0/text",
        "/title/simpleText",
        "/accessibility/accessibilityData/label",
        "/accessibilityData/accessibilityData/label",
    ]
    .iter()
    .find_map(|pointer| {
        renderer
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .map(|text| text.trim().to_string())
    })
    .or_else(|| first_text(renderer))
}

fn parse_action_text_state(text: Option<&str>, state: &mut MenuState) {
    let Some(text) = text else {
        return;
    };
    let lower = text.trim().to_ascii_lowercase();
    if (lower.starts_with("save ") && lower.ends_with(" to library")) || lower == "save to library"
    {
        state.library_known = true;
    } else if (lower.starts_with("remove ") && lower.ends_with(" from library"))
        || lower == "remove from library"
    {
        state.library_known = true;
        state.in_library = true;
    } else if lower == "subscribed"
        || lower == "unsubscribe"
        || lower.starts_with("subscribed to")
        || lower.starts_with("unsubscribe from")
    {
        state.subscribed = Some(true);
    } else if lower == "subscribe" || lower.starts_with("subscribe to") {
        state.subscribed.get_or_insert(false);
    }
}

fn collect_subscription_endpoints(value: &Value, state: &mut MenuState) {
    match value {
        Value::Object(object) => {
            if let Some(endpoint) = object
                .get("subscribeEndpoint")
                .and_then(subscription_endpoint_from_value)
            {
                state.subscribe_endpoint.get_or_insert(endpoint);
            }
            if let Some(endpoint) = object
                .get("unsubscribeEndpoint")
                .and_then(subscription_endpoint_from_value)
            {
                state.unsubscribe_endpoint.get_or_insert(endpoint);
            }
            for nested in object.values() {
                collect_subscription_endpoints(nested, state);
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_subscription_endpoints(nested, state);
            }
        }
        _ => {}
    }
}

fn parse_subscription_service_endpoint(
    renderer: &Value,
    key: &str,
    state: &mut MenuState,
    current: bool,
) {
    let Some(endpoint) = renderer.get(key) else {
        return;
    };
    if let Some(subscribe) = endpoint
        .get("subscribeEndpoint")
        .and_then(subscription_endpoint_from_value)
    {
        state.subscribe_endpoint.get_or_insert(subscribe);
        if current {
            state.subscribed = Some(false);
        }
    }
    if let Some(unsubscribe) = endpoint
        .get("unsubscribeEndpoint")
        .and_then(subscription_endpoint_from_value)
    {
        state.unsubscribe_endpoint.get_or_insert(unsubscribe);
        if current {
            state.subscribed = Some(true);
        }
    }
}

fn extract_feedback_token(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(|endpoint| endpoint.get("feedbackEndpoint"))
        .and_then(|feedback| feedback.get("feedbackToken"))
        .and_then(Value::as_str)
        .filter(|token| !token.trim().is_empty())
        .map(str::to_string)
}

fn subscription_endpoint_from_value(value: &Value) -> Option<SubscriptionEndpoint> {
    let channel_ids = value
        .get("channelIds")
        .and_then(Value::as_array)
        .map(|ids| {
            ids.iter()
                .filter_map(Value::as_str)
                .filter(|id| !id.trim().is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .filter(|ids| !ids.is_empty())
        .or_else(|| {
            value
                .get("channelId")
                .and_then(Value::as_str)
                .filter(|id| !id.trim().is_empty())
                .map(|id| vec![id.to_string()])
        })?;
    let params = value
        .get("params")
        .and_then(Value::as_str)
        .filter(|params| !params.trim().is_empty())
        .map(str::to_string);
    Some(SubscriptionEndpoint {
        channel_ids,
        params,
    })
}

fn channel_subscription_endpoint(browse_id: &str) -> Option<SubscriptionEndpoint> {
    (browse_id.starts_with("UC") && !browse_id.trim().is_empty()).then(|| SubscriptionEndpoint {
        channel_ids: vec![browse_id.to_string()],
        params: None,
    })
}

fn request_subscription_endpoint(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    action: &str,
    endpoint: &SubscriptionEndpoint,
) -> Result<()> {
    let path = match action {
        "subscribe" => "subscription/subscribe",
        "unsubscribe" => "subscription/unsubscribe",
        other => {
            return Err(HelperError::invalid_request(format!(
                "unknown subscription action `{other}`"
            )))
        }
    };
    let mut body = json!({
        "context": youtubei_context(auth, bootstrap),
        "channelIds": endpoint.channel_ids
    });
    if let Some(params) = endpoint.params.as_ref() {
        if let Some(object) = body.as_object_mut() {
            object.insert("params".to_string(), Value::String(params.clone()));
        }
    }
    request_youtubei_path(
        client,
        auth,
        bootstrap,
        path,
        &body,
        RequestPolicy::mutation(),
    )?;
    Ok(())
}

fn detail_mutation_output(
    browse_id: &str,
    response: &Value,
    action: &str,
    changed: bool,
    in_library: Option<bool>,
    subscribed: Option<bool>,
) -> Value {
    let mut output = normalize_browse_id_response(browse_id, MUTATION_DETAIL_LIMIT, response);
    apply_detail_account_state(&mut output, in_library, subscribed);
    if let Some(object) = output.as_object_mut() {
        object.insert(
            "browse-id".to_string(),
            Value::String(browse_id.to_string()),
        );
        object.insert("action".to_string(), Value::String(action.to_string()));
        object.insert("changed".to_string(), Value::Bool(changed));
        if let Some(in_library) = in_library {
            object.insert("in-library".to_string(), Value::Bool(in_library));
        }
        if let Some(subscribed) = subscribed {
            object.insert("subscribed".to_string(), Value::Bool(subscribed));
        }
        if let Some(playlist_id) = item_library_playlist_id(browse_id, response) {
            object.insert("playlist-id".to_string(), Value::String(playlist_id));
        }
    }
    output
}

fn apply_detail_account_state(
    output: &mut Value,
    in_library: Option<bool>,
    subscribed: Option<bool>,
) {
    let Some(sources) = output.get_mut("sources").and_then(Value::as_array_mut) else {
        return;
    };
    for source in sources {
        let Some(object) = source.as_object_mut() else {
            continue;
        };
        let kind = object
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let supports_library = detail_source_supports_library(kind);
        let supports_subscription = detail_source_supports_subscription(kind);
        if let Some(in_library) = in_library {
            if supports_library {
                object.insert("in-library".to_string(), Value::Bool(in_library));
            }
        }
        if let Some(subscribed) = subscribed {
            if supports_subscription {
                object.insert("subscribed".to_string(), Value::Bool(subscribed));
            }
        }
    }
}

fn detail_source_supports_library(kind: &str) -> bool {
    matches!(kind, "youtube-music-album" | "youtube-music-playlist")
}

fn detail_source_supports_subscription(kind: &str) -> bool {
    matches!(kind, "youtube-music-artist" | "youtube-channel")
}

fn insert_like_status(object: &mut Map<String, Value>, state: &MenuState) {
    if state.like_status_known {
        object.insert(
            "like-status".to_string(),
            state
                .like_status
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct LikeStatusState {
    known: bool,
    status: Option<String>,
}

impl LikeStatusState {
    fn known(status: Option<String>) -> Self {
        Self {
            known: true,
            status,
        }
    }
}

fn parse_like_status_state(value: &Value) -> LikeStatusState {
    match value {
        Value::Object(object) => {
            let mut result = LikeStatusState::default();
            if let Some(status) = object.get("likeStatus").and_then(Value::as_str) {
                let state = normalize_like_status(status);
                if state.status.is_some() {
                    return state;
                }
                result.known |= state.known;
            }
            if let Some(renderer) = object.get("toggleButtonRenderer") {
                let state = parse_toggle_like_status(renderer);
                if state.status.is_some() {
                    return state;
                }
                result.known |= state.known;
            }
            for nested in object.values() {
                let state = parse_like_status_state(nested);
                if state.status.is_some() {
                    return state;
                }
                result.known |= state.known;
            }
            result
        }
        Value::Array(array) => {
            let mut result = LikeStatusState::default();
            for nested in array {
                let state = parse_like_status_state(nested);
                if state.status.is_some() {
                    return state;
                }
                result.known |= state.known;
            }
            result
        }
        _ => LikeStatusState::default(),
    }
}

fn normalize_like_status(status: &str) -> LikeStatusState {
    match status.trim().to_ascii_uppercase().as_str() {
        "LIKE" => LikeStatusState::known(Some("like".to_string())),
        "DISLIKE" => LikeStatusState::known(Some("dislike".to_string())),
        "INDIFFERENT" => LikeStatusState::known(None),
        _ => LikeStatusState::default(),
    }
}

fn parse_toggle_like_status(renderer: &Value) -> LikeStatusState {
    let Some(is_toggled) = renderer.get("isToggled").and_then(Value::as_bool) else {
        return LikeStatusState::default();
    };
    let icon_type = renderer
        .pointer("/defaultIcon/iconType")
        .or_else(|| renderer.pointer("/toggledIcon/iconType"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let status = match icon_type {
        "LIKE" | "THUMB_UP" | "THUMB_UP_OUTLINE" => Some("like"),
        "DISLIKE" | "THUMB_DOWN" | "THUMB_DOWN_OUTLINE" => Some("dislike"),
        _ => None,
    };
    match (is_toggled, status) {
        (true, Some(status)) => LikeStatusState::known(Some(status.to_string())),
        (false, Some(_)) => LikeStatusState::known(None),
        _ => LikeStatusState::default(),
    }
}

fn find_radio_continuation(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(continuation) = object
                .get("nextRadioContinuationData")
                .and_then(|data| data.get("continuation"))
                .and_then(Value::as_str)
            {
                return Some(continuation.to_string());
            }
            object.values().find_map(find_radio_continuation)
        }
        Value::Array(array) => array.iter().find_map(find_radio_continuation),
        _ => None,
    }
}

fn collect_add_to_playlist_options(
    value: &Value,
    options: &mut Vec<Value>,
    seen: &mut HashSet<String>,
) {
    match value {
        Value::Object(object) => {
            for key in [
                "playlistAddToOptionRenderer",
                "addToPlaylistItemRenderer",
                "musicResponsiveListItemRenderer",
                "musicTwoRowItemRenderer",
            ] {
                if let Some(renderer) = object.get(key) {
                    if let Some(option) = parse_add_to_playlist_option(renderer) {
                        if let Some(playlist_id) = option.get("playlist-id").and_then(Value::as_str)
                        {
                            if seen.insert(playlist_id.to_string()) {
                                options.push(option);
                            }
                        }
                    }
                }
            }
            for nested in object.values() {
                collect_add_to_playlist_options(nested, options, seen);
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_add_to_playlist_options(nested, options, seen);
            }
        }
        _ => {}
    }
}

fn parse_add_to_playlist_option(renderer: &Value) -> Option<Value> {
    let playlist_id = find_playlist_id(renderer)?;
    let title = [
        "/title",
        "/text",
        "/label",
        "/primaryText",
        "/header",
        "/flexColumns",
        "/runs",
    ]
    .iter()
    .find_map(|pointer| renderer.pointer(pointer).and_then(first_text))
    .filter(|title| title != "Create new playlist" && title != "New playlist")
    .unwrap_or_else(|| "Unknown Playlist".to_string());
    let subtitle = ["/subtitle", "/secondaryText"]
        .iter()
        .find_map(|pointer| renderer.pointer(pointer).and_then(first_text));
    let thumbnail_url = find_best_thumbnail(renderer);
    Some(json!({
        "playlist-id": playlist_id,
        "title": title,
        "subtitle": subtitle,
        "thumbnail-url": thumbnail_url,
        "selected": find_first_bool_for_key(renderer, "selected").unwrap_or(false),
        "privacy-status": find_first_string_for_key(renderer, "privacyStatus")
    }))
}

fn find_playlist_id(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(playlist_id) = object
                .get("playlistId")
                .and_then(Value::as_str)
                .filter(|id| !id.trim().is_empty())
            {
                return Some(playlist_id.to_string());
            }
            if let Some(browse_id) = object.get("browseId").and_then(Value::as_str).filter(|id| {
                !id.trim().is_empty() && (id.starts_with("VL") || id.starts_with("PL"))
            }) {
                return Some(browse_id.to_string());
            }
            object.values().find_map(find_playlist_id)
        }
        Value::Array(array) => array.iter().find_map(find_playlist_id),
        _ => None,
    }
}

fn item_library_playlist_id(browse_id: &str, response: &Value) -> Option<String> {
    find_library_playlist_id(response)
        .or_else(|| browse_id_playlist_id(browse_id))
        .map(|id| clean_playlist_id(&id).to_string())
}

fn browse_id_playlist_id(browse_id: &str) -> Option<String> {
    let browse_id = browse_id.trim();
    (!browse_id.is_empty() && (browse_id.starts_with("VL") || browse_id.starts_with("PL")))
        .then(|| browse_id.to_string())
}

fn find_library_playlist_id(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(playlist_id) = object
                .get("playlistId")
                .and_then(Value::as_str)
                .filter(|id| is_library_playlist_id(id))
            {
                return Some(playlist_id.to_string());
            }
            object.values().find_map(find_library_playlist_id)
        }
        Value::Array(array) => array.iter().find_map(find_library_playlist_id),
        _ => None,
    }
}

fn is_library_playlist_id(playlist_id: &str) -> bool {
    let playlist_id = playlist_id.trim();
    !playlist_id.is_empty()
        && !playlist_id.starts_with("RD")
        && !playlist_id.starts_with("LM")
        && !playlist_id.starts_with("RDAMVM")
        && !playlist_id.starts_with("RDAMP")
}

fn find_first_bool_for_key(value: &Value, key: &str) -> Option<bool> {
    match value {
        Value::Object(object) => object.get(key).and_then(Value::as_bool).or_else(|| {
            object
                .values()
                .find_map(|nested| find_first_bool_for_key(nested, key))
        }),
        Value::Array(array) => array
            .iter()
            .find_map(|nested| find_first_bool_for_key(nested, key)),
        _ => None,
    }
}

fn find_object_named<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(object) => {
            if let Some(found) = object.get(key) {
                return Some(found);
            }
            object
                .values()
                .find_map(|nested| find_object_named(nested, key))
        }
        Value::Array(array) => array
            .iter()
            .find_map(|nested| find_object_named(nested, key)),
        _ => None,
    }
}

fn contains_object_key(value: &Value, key: &str) -> bool {
    match value {
        Value::Object(object) => {
            object.contains_key(key)
                || object
                    .values()
                    .any(|nested| contains_object_key(nested, key))
        }
        Value::Array(array) => array.iter().any(|nested| contains_object_key(nested, key)),
        _ => false,
    }
}

fn clean_playlist_id(playlist_id: &str) -> &str {
    playlist_id
        .strip_prefix("VL")
        .filter(|id| !id.is_empty())
        .unwrap_or(playlist_id)
}

fn browse_response_title(value: &Value) -> Option<String> {
    [
        "/header/musicDetailHeaderRenderer/title/runs/0/text",
        "/header/musicImmersiveHeaderRenderer/title/runs/0/text",
        "/header/musicVisualHeaderRenderer/title/runs/0/text",
        "/header/musicEditablePlaylistDetailHeaderRenderer/header/musicDetailHeaderRenderer/title/runs/0/text",
        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/title",
        "/metadata/musicDetailHeaderRenderer/title/runs/0/text",
    ]
    .iter()
    .find_map(|pointer| {
        value
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string)
    })
    .or_else(|| find_header_title(value))
}

fn browse_response_subtitle(value: &Value, title: &str, kind: &str) -> Option<String> {
    let header = find_header_renderer(value)?;
    let mut seen = HashSet::new();
    let parts: Vec<String> = collect_text_runs(header)
        .into_iter()
        .filter_map(|run| {
            let text = run.text.trim();
            let lower = text.to_ascii_lowercase();
            (!text.is_empty()
                && text != title
                && !is_separator(text)
                && !is_action_text(text)
                && !is_header_noise_text(text, kind)
                && parse_duration(text).is_none()
                && !matches!(
                    lower.as_str(),
                    "less"
                        | "mix"
                        | "more"
                        | "shuffle"
                        | "radio"
                        | "share"
                        | "subscribe"
                        | "subscribed"
                        | "unsubscribe"
                        | "unsubscribed"
                        | "play"
                )
                && seen.insert(text.to_string()))
            .then_some(text.to_string())
        })
        .take(4)
        .collect();
    (!parts.is_empty()).then(|| parts.join(" - "))
}

fn browse_response_thumbnail_url(value: &Value) -> Option<String> {
    find_header_renderer(value).and_then(find_best_thumbnail)
}

fn find_header_renderer(value: &Value) -> Option<&Value> {
    match value {
        Value::Object(object) => {
            for renderer_name in [
                "musicDetailHeaderRenderer",
                "musicImmersiveHeaderRenderer",
                "musicEditablePlaylistDetailHeaderRenderer",
                "musicVisualHeaderRenderer",
                "musicHeaderRenderer",
            ] {
                if let Some(renderer) = object.get(renderer_name) {
                    return Some(renderer);
                }
            }
            object.values().find_map(find_header_renderer)
        }
        Value::Array(array) => array.iter().find_map(find_header_renderer),
        _ => None,
    }
}

fn find_header_title(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            for renderer_name in [
                "musicDetailHeaderRenderer",
                "musicImmersiveHeaderRenderer",
                "musicEditablePlaylistDetailHeaderRenderer",
                "musicVisualHeaderRenderer",
                "musicHeaderRenderer",
            ] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(title) = section_title(renderer).or_else(|| first_text(renderer)) {
                        return Some(title);
                    }
                }
            }
            object.values().find_map(find_header_title)
        }
        Value::Array(array) => array.iter().find_map(find_header_title),
        _ => None,
    }
}

struct MusicSection {
    title: String,
    items: Vec<Value>,
    continuation: Option<String>,
}

fn collect_sections(value: &Value, sections: &mut Vec<MusicSection>, limit: usize) {
    match value {
        Value::Object(object) => {
            for renderer_name in [
                "musicCardShelfRenderer",
                "musicCarouselShelfRenderer",
                "musicShelfRenderer",
                "gridRenderer",
                "richShelfRenderer",
            ] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(section) =
                        parse_renderer_section(renderer_name, renderer, sections.len() + 1, limit)
                    {
                        sections.push(section);
                    }
                    return;
                }
            }
            for nested in object.values() {
                collect_sections(nested, sections, limit);
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_sections(nested, sections, limit);
            }
        }
        _ => {}
    }
}

fn collect_browse_sections(value: &Value, sections: &mut Vec<MusicSection>, limit: usize) {
    if let Some(root) = primary_browse_section_root(value) {
        collect_sections(root, sections, limit);
    } else {
        collect_sections(value, sections, limit);
    }
}

fn collect_browse_items(
    value: &Value,
    items: &mut Vec<Value>,
    seen: &mut HashSet<String>,
    limit: usize,
) {
    if let Some(root) = primary_browse_section_root(value) {
        collect_items(root, items, seen, limit);
    } else {
        collect_items(value, items, seen, limit);
    }
}

fn primary_browse_section_root(value: &Value) -> Option<&Value> {
    [
        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents",
        "/contents/singleColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer",
        "/contents/twoColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer/contents",
        "/contents/twoColumnBrowseResultsRenderer/tabs/0/tabRenderer/content/sectionListRenderer",
    ]
    .iter()
    .find_map(|pointer| value.pointer(pointer))
}

fn parse_renderer_section(
    renderer_name: &str,
    renderer: &Value,
    index: usize,
    limit: usize,
) -> Option<MusicSection> {
    if renderer_name == "musicCardShelfRenderer" {
        return parse_card_shelf_section(renderer, index, limit);
    }
    parse_section(renderer, index, limit)
}

fn parse_section(renderer: &Value, index: usize, limit: usize) -> Option<MusicSection> {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    collect_items(renderer, &mut items, &mut seen, limit);
    if items.is_empty() {
        return None;
    }
    Some(MusicSection {
        title: section_title(renderer).unwrap_or_else(|| format!("Home section {index}")),
        items,
        continuation: find_first_string_for_key(renderer, "continuation"),
    })
}

fn parse_card_shelf_section(renderer: &Value, _index: usize, limit: usize) -> Option<MusicSection> {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    if let Some(item) = parse_card_shelf_header(renderer) {
        seen.insert(item_dedupe_key(&item));
        items.push(item);
    }
    if items.len() < limit {
        if let Some(contents) = renderer.get("contents") {
            collect_items(contents, &mut items, &mut seen, limit);
        }
    }
    if items.is_empty() {
        return None;
    }
    Some(MusicSection {
        title: "Top result".to_string(),
        items,
        continuation: find_first_string_for_key(renderer, "continuation"),
    })
}

fn section_title(renderer: &Value) -> Option<String> {
    [
        "/header/musicCarouselShelfBasicHeaderRenderer/title/runs/0/text",
        "/header/musicHeaderRenderer/title/runs/0/text",
        "/header/title/runs/0/text",
        "/header/title/simpleText",
        "/title/runs/0/text",
        "/title/simpleText",
    ]
    .iter()
    .find_map(|pointer| {
        renderer
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string)
    })
    .or_else(|| renderer.get("header").and_then(first_text))
}

fn first_text(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(text) = object
                .get("text")
                .and_then(Value::as_str)
                .filter(|text| !text.trim().is_empty() && !is_separator(text))
            {
                return Some(text.to_string());
            }
            object.values().find_map(first_text)
        }
        Value::Array(array) => array.iter().find_map(first_text),
        _ => None,
    }
}

fn section_id(parent_id: &str, title: &str, index: usize) -> String {
    let slug = slugify(title);
    if slug.is_empty() {
        format!("{parent_id}:{index}:{}", short_hash(title))
    } else {
        format!("{parent_id}:{index}:{slug}")
    }
}

fn url_query_encode(input: &str) -> String {
    let mut output = String::new();
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                output.push(byte as char)
            }
            b' ' => output.push('+'),
            _ => output.push_str(&format!("%{byte:02X}")),
        }
    }
    output
}

fn slugify(input: &str) -> String {
    let mut output = String::new();
    let mut pending_dash = false;
    for character in input.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_alphanumeric() {
            if pending_dash && !output.is_empty() {
                output.push('-');
            }
            pending_dash = false;
            output.push(character);
        } else {
            pending_dash = true;
        }
    }
    output
}

fn short_hash(input: &str) -> String {
    let digest = Sha1::digest(input.as_bytes());
    format!("{digest:x}").chars().take(8).collect()
}

fn collect_items(value: &Value, items: &mut Vec<Value>, seen: &mut HashSet<String>, limit: usize) {
    collect_items_matching(value, items, seen, limit, &|_| true);
}

fn collect_items_for_target(
    target: &BrowseTarget,
    value: &Value,
    items: &mut Vec<Value>,
    seen: &mut HashSet<String>,
    limit: usize,
) {
    collect_items_matching(value, items, seen, limit, &|item| {
        !is_target_action_item(target, item)
    });
}

fn collect_items_matching<F>(
    value: &Value,
    items: &mut Vec<Value>,
    seen: &mut HashSet<String>,
    limit: usize,
    include_item: &F,
) where
    F: Fn(&Value) -> bool,
{
    if items.len() >= limit {
        return;
    }
    match value {
        Value::Object(object) => {
            for renderer_name in [
                "musicResponsiveListItemRenderer",
                "musicTwoRowItemRenderer",
                "compactVideoRenderer",
                "gridVideoRenderer",
                "videoRenderer",
            ] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(item) = parse_item(renderer) {
                        if include_item(&item) && seen.insert(item_dedupe_key(&item)) {
                            items.push(item);
                        }
                        return;
                    }
                }
            }
            for nested in object.values() {
                collect_items_matching(nested, items, seen, limit, include_item);
                if items.len() >= limit {
                    break;
                }
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_items_matching(nested, items, seen, limit, include_item);
                if items.len() >= limit {
                    break;
                }
            }
        }
        _ => {}
    }
}

fn is_target_action_item(target: &BrowseTarget, item: &Value) -> bool {
    match target {
        BrowseTarget::LibrarySongs => is_library_songs_shuffle_action(item),
        BrowseTarget::LibraryPlaylists => is_library_playlists_new_playlist_action(item),
        _ => false,
    }
}

fn is_library_songs_shuffle_action(item: &Value) -> bool {
    // YouTube Music emits Library Songs' "Shuffle all" button as a playlist item.
    item.get("type").and_then(Value::as_str) == Some("playlist")
        && item.get("playlist-id").and_then(Value::as_str) == Some("MLCT")
}

fn is_library_playlists_new_playlist_action(item: &Value) -> bool {
    // YouTube Music emits Library Playlists' "New playlist" button as an item.
    let thumbnail_url = item
        .get("thumbnail-url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    item.get("type").and_then(Value::as_str) == Some("item")
        && item.get("browse-id").and_then(Value::as_str).is_none()
        && item.get("playlist-id").and_then(Value::as_str).is_none()
        && item.get("url").and_then(Value::as_str).is_none()
        && thumbnail_url.contains("/pbg/create-playlist-")
}

fn parse_card_shelf_header(renderer: &Value) -> Option<Value> {
    if let Some(item) = parse_card_shelf_playable_header(renderer) {
        return Some(item);
    }

    let title = renderer_title(renderer)?;
    let runs = item_metadata_runs(renderer);
    let browse_endpoint = find_direct_browse_endpoint(renderer);
    let browse_id = browse_endpoint
        .as_ref()
        .map(|endpoint| endpoint.browse_id.clone());
    let browse_params = browse_endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.params.clone());
    let browse_page_type = browse_endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.page_type.as_deref());
    let playlist_id = renderer
        .pointer("/navigationEndpoint/watchEndpoint/playlistId")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            renderer
                .pointer("/title/runs/0/navigationEndpoint/watchEndpoint/playlistId")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
    let id = browse_id
        .clone()
        .or_else(|| playlist_id.clone())
        .unwrap_or_else(|| format!("item:{title}"));
    let kind = item_kind(
        browse_page_type,
        browse_id.as_deref(),
        playlist_id.as_deref(),
        &runs,
    );
    let subtitle = metadata_subtitle(&title, &runs);
    let metadata = metadata_tokens(&title, &runs);
    let thumbnail_url = renderer
        .get("thumbnail")
        .and_then(find_best_thumbnail)
        .or_else(|| {
            renderer
                .get("thumbnailRenderer")
                .and_then(find_best_thumbnail)
        })
        .or_else(|| find_best_thumbnail(renderer));
    let url = item_url(&kind, browse_id.as_deref(), playlist_id.as_deref());
    let state = panel_menu_state(renderer);
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String(kind)),
        ("id".to_string(), Value::String(id)),
        ("title".to_string(), Value::String(title)),
        (
            "subtitle".to_string(),
            subtitle.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "metadata".to_string(),
            if metadata.is_empty() {
                Value::Null
            } else {
                Value::Array(metadata)
            },
        ),
        (
            "url".to_string(),
            url.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "browse-id".to_string(),
            browse_id.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "browse-params".to_string(),
            browse_params.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "playlist-id".to_string(),
            playlist_id.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "in-library".to_string(),
            menu_state_in_library_value(&state),
        ),
        (
            "subscribed".to_string(),
            state.subscribed.map(Value::Bool).unwrap_or(Value::Null),
        ),
    ]);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn parse_card_shelf_playable_header(renderer: &Value) -> Option<Value> {
    let video_id = find_primary_watch_endpoint(renderer)?.video_id;
    let title = renderer_title(renderer)?;
    let runs = item_metadata_runs(renderer);
    if !runs
        .iter()
        .any(|run| playable_kind_metadata_text(&run.text))
    {
        return None;
    }
    let kind = playable_item_kind(&runs);
    let artist = runs
        .iter()
        .find(|run| {
            run.browse_id
                .as_deref()
                .is_some_and(|id| id.starts_with("UC"))
        })
        .map(|run| run.text.clone())
        .or_else(|| {
            runs.iter()
                .find(|run| {
                    item_metadata_text(&title, &run.text) && !playable_kind_metadata_text(&run.text)
                })
                .map(|run| run.text.clone())
        });
    let album = runs
        .iter()
        .find(|run| {
            run.browse_id
                .as_deref()
                .is_some_and(|id| id.starts_with("MPRE"))
        })
        .map(|run| run.text.clone());
    let duration = runs.iter().find_map(|run| parse_duration(&run.text));
    let thumbnail_url = renderer
        .get("thumbnail")
        .and_then(find_best_thumbnail)
        .or_else(|| {
            renderer
                .get("thumbnailRenderer")
                .and_then(find_best_thumbnail)
        })
        .or_else(|| find_best_thumbnail(renderer));
    let menu = panel_menu_state(renderer);
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String(kind)),
        ("id".to_string(), Value::String(video_id.clone())),
        ("title".to_string(), Value::String(title)),
        (
            "url".to_string(),
            Value::String(format!("https://music.youtube.com/watch?v={video_id}")),
        ),
        (
            "artist".to_string(),
            artist.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "album".to_string(),
            album.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "duration".to_string(),
            duration.map(Value::from).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
        ("in-library".to_string(), menu_state_in_library_value(&menu)),
    ]);
    insert_like_status(&mut item, &menu);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn item_dedupe_key(item: &Value) -> String {
    item.get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| item.get("title").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string()
}

fn parse_item(renderer: &Value) -> Option<Value> {
    if find_direct_browse_endpoint(renderer).is_some() {
        parse_card(renderer).or_else(|| parse_track(renderer))
    } else {
        parse_track(renderer).or_else(|| parse_card(renderer))
    }
}

fn parse_track(renderer: &Value) -> Option<Value> {
    let video_id = find_primary_watch_endpoint(renderer)?.video_id;
    let title = renderer_title(renderer)?;
    let runs = collect_text_runs(renderer);
    let kind = playable_item_kind(&runs);
    let artist = runs
        .iter()
        .find(|run| {
            run.browse_id
                .as_deref()
                .is_some_and(|id| id.starts_with("UC"))
        })
        .map(|run| run.text.clone())
        .or_else(|| {
            runs.iter()
                .find(|run| item_metadata_text(&title, &run.text))
                .map(|run| run.text.clone())
        });
    let album = runs
        .iter()
        .find(|run| {
            run.browse_id
                .as_deref()
                .is_some_and(|id| id.starts_with("MPRE"))
        })
        .map(|run| run.text.clone());
    let duration = runs.iter().find_map(|run| parse_duration(&run.text));
    let thumbnail_url = find_best_thumbnail(renderer);
    let menu = panel_menu_state(renderer);
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String(kind)),
        ("id".to_string(), Value::String(video_id.clone())),
        ("title".to_string(), Value::String(title)),
        (
            "url".to_string(),
            Value::String(format!("https://music.youtube.com/watch?v={video_id}")),
        ),
        (
            "artist".to_string(),
            artist.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "album".to_string(),
            album.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "duration".to_string(),
            duration.map(Value::from).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
        ("in-library".to_string(), Value::Bool(menu.in_library)),
    ]);
    insert_like_status(&mut item, &menu);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn parse_card(renderer: &Value) -> Option<Value> {
    let title = renderer_title(renderer).or_else(|| {
        collect_text_runs(renderer)
            .into_iter()
            .find(|run| !is_separator(&run.text))
            .map(|run| run.text)
    })?;
    let runs = collect_text_runs(renderer);
    let metadata_runs = item_metadata_runs(renderer);
    let browse_endpoint = find_primary_browse_endpoint(renderer);
    let browse_id = browse_endpoint
        .as_ref()
        .map(|endpoint| endpoint.browse_id.clone())
        .or_else(|| find_first_string_for_key(renderer, "browseId"));
    let browse_params = browse_endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.params.clone());
    let browse_page_type = browse_endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.page_type.as_deref());
    let playlist_id = find_first_string_for_key(renderer, "playlistId");
    let id = browse_id
        .clone()
        .or_else(|| playlist_id.clone())
        .unwrap_or_else(|| format!("item:{title}"));
    let kind = item_kind(
        browse_page_type,
        browse_id.as_deref(),
        playlist_id.as_deref(),
        &runs,
    );
    let subtitle = metadata_subtitle(&title, &metadata_runs);
    let metadata = metadata_tokens(&title, &metadata_runs);
    let thumbnail_url = find_best_thumbnail(renderer);
    let url = item_url(&kind, browse_id.as_deref(), playlist_id.as_deref());
    let state = panel_menu_state(renderer);
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String(kind)),
        ("id".to_string(), Value::String(id)),
        ("title".to_string(), Value::String(title)),
        (
            "subtitle".to_string(),
            subtitle.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "metadata".to_string(),
            if metadata.is_empty() {
                Value::Null
            } else {
                Value::Array(metadata)
            },
        ),
        (
            "url".to_string(),
            url.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "browse-id".to_string(),
            browse_id.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "browse-params".to_string(),
            browse_params.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "playlist-id".to_string(),
            playlist_id.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "in-library".to_string(),
            menu_state_in_library_value(&state),
        ),
        (
            "subscribed".to_string(),
            state.subscribed.map(Value::Bool).unwrap_or(Value::Null),
        ),
    ]);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn renderer_title(renderer: &Value) -> Option<String> {
    [
        "/title/runs/0/text",
        "/title/simpleText",
        "/headline/runs/0/text",
        "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text",
    ]
    .iter()
    .find_map(|pointer| {
        renderer
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string)
    })
}

fn playable_item_kind(runs: &[TextRun]) -> String {
    if text_runs_contain(runs, "episode") || text_runs_contain(runs, "podcast") {
        "episode".to_string()
    } else {
        "track".to_string()
    }
}

fn item_kind(
    page_type: Option<&str>,
    browse_id: Option<&str>,
    playlist_id: Option<&str>,
    runs: &[TextRun],
) -> String {
    if let Some(kind) = item_kind_from_page_type(page_type) {
        return kind.to_string();
    }
    match browse_id.unwrap_or_default() {
        id if id.starts_with("MPRE") => "album",
        id if id.starts_with("UC") => "artist",
        id if id.starts_with("VL") || id.starts_with("PL") || id.starts_with("RD") => "playlist",
        id if id.starts_with("MPSP") => "podcast",
        id if id.starts_with("MPED") => "episode",
        _ if playlist_id.is_some() => "playlist",
        _ if text_runs_contain(runs, "podcast") => "podcast",
        _ if text_runs_contain(runs, "episode") => "episode",
        _ => "item",
    }
    .to_string()
}

fn item_kind_from_page_type(page_type: Option<&str>) -> Option<&'static str> {
    match page_type? {
        "MUSIC_PAGE_TYPE_ALBUM" => Some("album"),
        "MUSIC_PAGE_TYPE_ARTIST" | "MUSIC_PAGE_TYPE_USER_CHANNEL" => Some("artist"),
        "MUSIC_PAGE_TYPE_PLAYLIST" => Some("playlist"),
        "MUSIC_PAGE_TYPE_PODCAST_SHOW" => Some("podcast"),
        "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE" | "MUSIC_PAGE_TYPE_PODCAST_EPISODE" => {
            Some("episode")
        }
        _ => None,
    }
}

fn item_url(kind: &str, browse_id: Option<&str>, playlist_id: Option<&str>) -> Option<String> {
    if let Some(playlist_id) = playlist_id {
        return Some(format!(
            "https://music.youtube.com/playlist?list={playlist_id}"
        ));
    }
    browse_id.map(|browse_id| match kind {
        "album" | "artist" | "playlist" | "item" => {
            format!("https://music.youtube.com/browse/{browse_id}")
        }
        _ => format!("https://music.youtube.com/browse/{browse_id}"),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WatchEndpoint {
    video_id: String,
}

fn find_primary_watch_endpoint(renderer: &Value) -> Option<WatchEndpoint> {
    [
        "/navigationEndpoint",
        "/title/runs/0/navigationEndpoint",
        "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/navigationEndpoint",
    ]
    .iter()
    .find_map(|path| {
        renderer
            .pointer(path)
            .and_then(watch_endpoint_from_navigation_endpoint)
    })
}

fn watch_endpoint_from_navigation_endpoint(value: &Value) -> Option<WatchEndpoint> {
    let video_id = value
        .get("watchEndpoint")
        .and_then(|value| value.get("videoId"))
        .and_then(Value::as_str)?
        .to_string();
    Some(WatchEndpoint { video_id })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BrowseEndpoint {
    browse_id: String,
    params: Option<String>,
    page_type: Option<String>,
}

fn find_primary_browse_endpoint(renderer: &Value) -> Option<BrowseEndpoint> {
    find_direct_browse_endpoint(renderer).or_else(|| find_first_browse_endpoint(renderer))
}

fn find_direct_browse_endpoint(renderer: &Value) -> Option<BrowseEndpoint> {
    [
        "/navigationEndpoint",
        "/title/runs/0/navigationEndpoint",
        "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/navigationEndpoint",
    ]
    .iter()
    .find_map(|path| {
        renderer
            .pointer(path)
            .and_then(browse_endpoint_from_navigation_endpoint)
    })
}

fn browse_endpoint_from_navigation_endpoint(value: &Value) -> Option<BrowseEndpoint> {
    value
        .get("browseEndpoint")
        .and_then(browse_endpoint_from_browse_endpoint)
}

fn browse_endpoint_from_browse_endpoint(value: &Value) -> Option<BrowseEndpoint> {
    let browse_id = value.get("browseId").and_then(Value::as_str)?.to_string();
    let params = value
        .get("params")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string);
    let page_type = value
        .pointer("/browseEndpointContextSupportedConfigs/browseEndpointContextMusicConfig/pageType")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string);
    Some(BrowseEndpoint {
        browse_id,
        params,
        page_type,
    })
}

fn find_first_browse_endpoint(value: &Value) -> Option<BrowseEndpoint> {
    match value {
        Value::Object(object) => {
            if let Some(endpoint) = object
                .get("browseEndpoint")
                .and_then(browse_endpoint_from_browse_endpoint)
            {
                return Some(endpoint);
            }
            object.values().find_map(find_first_browse_endpoint)
        }
        Value::Array(array) => array.iter().find_map(find_first_browse_endpoint),
        _ => None,
    }
}

#[derive(Debug)]
struct TextRun {
    text: String,
    browse_id: Option<String>,
    browse_params: Option<String>,
}

fn collect_text_runs(value: &Value) -> Vec<TextRun> {
    let mut output = Vec::new();
    collect_text_runs_into(value, &mut output);
    output
}

fn text_runs_contain(runs: &[TextRun], needle: &str) -> bool {
    runs.iter()
        .any(|run| run.text.to_ascii_lowercase().contains(needle))
}

fn collect_text_runs_into(value: &Value, output: &mut Vec<TextRun>) {
    match value {
        Value::Object(object) => {
            if let Some(text) = object.get("text").and_then(Value::as_str) {
                output.push(TextRun {
                    text: text.to_string(),
                    browse_id: object
                        .get("navigationEndpoint")
                        .and_then(browse_endpoint_from_navigation_endpoint)
                        .map(|endpoint| endpoint.browse_id),
                    browse_params: object
                        .get("navigationEndpoint")
                        .and_then(browse_endpoint_from_navigation_endpoint)
                        .and_then(|endpoint| endpoint.params),
                });
            }
            for nested in object.values() {
                collect_text_runs_into(nested, output);
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_text_runs_into(nested, output);
            }
        }
        _ => {}
    }
}

fn item_metadata_runs(renderer: &Value) -> Vec<TextRun> {
    let mut runs = Vec::new();
    for pointer in [
        "/subtitle",
        "/secondSubtitle",
        "/subtitleBadges",
        "/description",
        "/flexColumns/1/musicResponsiveListItemFlexColumnRenderer/text",
        "/flexColumns/2/musicResponsiveListItemFlexColumnRenderer/text",
        "/flexColumns/3/musicResponsiveListItemFlexColumnRenderer/text",
    ] {
        if let Some(value) = renderer.pointer(pointer) {
            collect_text_runs_into(value, &mut runs);
        }
    }
    runs
}

fn metadata_run_text(title: &str, run: &TextRun) -> Option<String> {
    let text = run.text.trim();
    (!text.is_empty() && text != title && !is_action_text(text) && parse_duration(text).is_none())
        .then_some(text.to_string())
}

fn metadata_subtitle(title: &str, runs: &[TextRun]) -> Option<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    for run in runs {
        let Some(text) = metadata_run_text(title, run) else {
            continue;
        };
        if is_bullet_separator(&text) {
            if !current.trim().is_empty() {
                parts.push(current.trim().to_string());
                current.clear();
            }
        } else if is_inline_separator(&text) {
            if !current.trim().is_empty() && !current.ends_with(' ') {
                current.push(' ');
            }
            current.push_str(text.trim());
            current.push(' ');
        } else {
            if !current.trim().is_empty() && !current.ends_with(' ') {
                current.push(' ');
            }
            current.push_str(text.trim());
        }
    }
    if !current.trim().is_empty() {
        parts.push(current.trim().to_string());
    }
    parts.dedup();
    (!parts.is_empty()).then(|| parts.into_iter().take(4).collect::<Vec<_>>().join(" - "))
}

fn metadata_tokens(title: &str, runs: &[TextRun]) -> Vec<Value> {
    let mut tokens = Vec::new();
    let mut pending_separator = false;
    for run in runs {
        let Some(text) = metadata_run_text(title, run) else {
            continue;
        };
        if is_bullet_separator(&text) {
            pending_separator = !tokens.is_empty();
            continue;
        }
        let text = if is_inline_separator(&text) {
            format!(" {} ", text.trim())
        } else if pending_separator {
            pending_separator = false;
            format!(" - {}", text.trim())
        } else {
            text.trim().to_string()
        };
        let mut token = Map::from_iter([("text".to_string(), Value::String(text))]);
        if let Some(browse_id) = run.browse_id.as_ref() {
            token.insert("browse-id".to_string(), Value::String(browse_id.clone()));
        }
        if let Some(params) = run.browse_params.as_ref() {
            token.insert("browse-params".to_string(), Value::String(params.clone()));
        }
        tokens.push(Value::Object(token));
    }
    tokens
}

fn find_first_string_for_key(value: &Value, key: &str) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(result) = object.get(key).and_then(Value::as_str) {
                return Some(result.to_string());
            }
            object
                .values()
                .find_map(|nested| find_first_string_for_key(nested, key))
        }
        Value::Array(array) => array
            .iter()
            .find_map(|nested| find_first_string_for_key(nested, key)),
        _ => None,
    }
}

fn find_best_thumbnail(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => {
            if let Some(thumbnails) = object.get("thumbnails").and_then(Value::as_array) {
                if let Some(url) = thumbnails
                    .last()
                    .and_then(|thumbnail| thumbnail.get("url"))
                    .and_then(Value::as_str)
                {
                    return Some(url.to_string());
                }
            }
            object.values().find_map(find_best_thumbnail)
        }
        Value::Array(array) => array.iter().find_map(find_best_thumbnail),
        _ => None,
    }
}

fn is_separator(text: &str) -> bool {
    matches!(text.trim(), "" | "•" | "·" | "&")
}

fn is_bullet_separator(text: &str) -> bool {
    matches!(text.trim(), "•" | "·")
}

fn is_inline_separator(text: &str) -> bool {
    matches!(text.trim(), "&")
}

fn is_action_text(text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    lower.ends_with(" will play next")
        || lower.ends_with(" added to queue")
        || (lower.starts_with("save ") && lower.ends_with(" to library"))
        || (lower.starts_with("remove ") && lower.ends_with(" from library"))
        || lower.starts_with("add to ")
        || lower.starts_with("remove from ")
        || lower.starts_with("save to ")
        || lower.starts_with("subscribe to")
        || lower.starts_with("subscribed to")
        || lower.starts_with("unsubscribe from")
        || matches!(
            lower.as_str(),
            "cancel"
                | "change privacy"
                | "create"
                | "download"
                | "edit playlist"
                | "go to album"
                | "go to artist"
                | "learn more"
                | "less"
                | "mix"
                | "more"
                | "more actions"
                | "more options"
                | "play"
                | "play next"
                | "radio"
                | "remove from library"
                | "remove from queue"
                | "save to library"
                | "share"
                | "shuffle"
                | "shuffle play"
                | "start mix"
                | "subscribe"
                | "subscribed"
                | "unsubscribe"
                | "unsubscribed"
        )
}

fn is_header_noise_text(text: &str, kind: &str) -> bool {
    let text = text.trim();
    kind == "youtube-music-artist"
        && (matches!(text, "?" | "??") || text.chars().all(|char| char.is_ascii_digit()))
}

fn item_metadata_text(title: &str, text: &str) -> bool {
    let text = text.trim();
    !text.is_empty()
        && text != title
        && !is_separator(text)
        && !is_action_text(text)
        && parse_duration(text).is_none()
}

fn playable_kind_metadata_text(text: &str) -> bool {
    matches!(
        text.trim().to_ascii_lowercase().as_str(),
        "song" | "track" | "video" | "music video" | "episode" | "podcast" | "podcast episode"
    )
}

fn parse_duration(text: &str) -> Option<u64> {
    let parts: Vec<&str> = text.split(':').collect();
    if !(2..=3).contains(&parts.len()) || parts.iter().any(|part| part.parse::<u64>().is_err()) {
        return None;
    }
    parts.iter().try_fold(0_u64, |total, part| {
        Some(total * 60 + part.parse::<u64>().ok()?)
    })
}

#[cfg(test)]
#[path = "ytmusic/tests.rs"]
mod tests;
