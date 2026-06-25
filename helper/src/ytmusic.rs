use crate::auth::AuthConfig;
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, CONTENT_TYPE, USER_AGENT};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha1::{Digest, Sha1};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::Write;
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
const RESPONSE_CACHE_SEARCH_TTL_SECS: u64 = 2 * 60;
const RESPONSE_CACHE_DETAIL_TTL_SECS: u64 = 30 * 60;
const RESPONSE_CACHE_MAX_ENTRIES: usize = 80;
const TIMINGS_ENV: &str = "YTM_RADIO_TIMINGS";

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

const LIBRARY_TARGETS: [BrowseTarget; 5] = [
    BrowseTarget::LibrarySongs,
    BrowseTarget::LibraryAlbums,
    BrowseTarget::LibraryArtists,
    BrowseTarget::LibraryPlaylists,
    BrowseTarget::Liked,
];

pub fn browse(
    target: &BrowseTarget,
    limit: usize,
    auth: &AuthConfig,
    initial_only: bool,
    bootstrap_cache: Option<&Path>,
) -> Result<Value, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
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
) -> Result<Value, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
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
) -> Result<Value, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_browse_id(
        &client,
        auth,
        &bootstrap,
        browse_id,
        params,
        bootstrap_cache.map(response_cache_dir).as_deref(),
    )?;
    Ok(normalize_browse_id_response(browse_id, limit, &response))
}

pub fn search(
    query: &str,
    limit: usize,
    auth: &AuthConfig,
    bootstrap_cache: Option<&Path>,
) -> Result<Value, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let bootstrap = bootstrap_with_cache(&client, auth, bootstrap_cache)?;
    let response = request_search(
        &client,
        auth,
        &bootstrap,
        query,
        bootstrap_cache.map(response_cache_dir).as_deref(),
    )?;
    Ok(normalize_search_response(query, limit, &response))
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

fn bootstrap_with_cache(
    client: &Client,
    auth: &AuthConfig,
    cache_path: Option<&Path>,
) -> Result<Bootstrap, String> {
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

fn save_bootstrap_cache(path: &Path, bootstrap: &Bootstrap) -> Result<(), String> {
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
) -> Result<String, String> {
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

fn save_response_cache(path: &Path, value: &Value, ttl_secs: u64) -> Result<(), String> {
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

fn write_private_bytes(path: &Path, content: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create `{}`: {error}", parent.display()))?;
    }
    write_private_file(path, content)
}

#[cfg(unix)]
fn write_private_file(path: &Path, content: &[u8]) -> Result<(), String> {
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
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("cannot set permissions on `{}`: {error}", path.display()))
}

#[cfg(not(unix))]
fn write_private_file(path: &Path, content: &[u8]) -> Result<(), String> {
    fs::write(path, content).map_err(|error| format!("cannot write `{}`: {error}", path.display()))
}

fn bootstrap(client: &Client, auth: &AuthConfig) -> Result<Bootstrap, String> {
    let response = client
        .get(YTM_ORIGIN)
        .headers(base_headers(auth)?)
        .send()
        .map_err(|error| format!("cannot load YouTube Music: {error}"))?;
    let status = response.status();
    let html = response
        .text()
        .map_err(|error| format!("cannot read YouTube Music bootstrap: {error}"))?;
    if !status.is_success() {
        return Err(format!("YouTube Music bootstrap returned HTTP {status}"));
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
) -> Result<Value, String> {
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
) -> Result<Value, String> {
    request_browse_id_with_ttl(
        client,
        auth,
        bootstrap,
        browse_id,
        params,
        cache_dir,
        RESPONSE_CACHE_DETAIL_TTL_SECS,
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
) -> Result<Value, String> {
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
) -> Result<Value, String> {
    let normalized_sections = thread::scope(|scope| {
        let handles = LIBRARY_TARGETS
            .into_iter()
            .map(|target| {
                let client = client.clone();
                scope.spawn(move || {
                    let response = request_browse(&client, auth, bootstrap, &target, cache_dir)?;
                    Ok::<Value, String>(normalize_single_source_response(&target, limit, &response))
                })
            })
            .collect::<Vec<_>>();

        let mut sections = Vec::with_capacity(handles.len());
        for handle in handles {
            sections.push(
                handle
                    .join()
                    .map_err(|_| "YouTube Music library request thread panicked".to_string())??,
            );
        }
        Ok::<Vec<Value>, String>(sections)
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
) -> Result<Value, String> {
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
        cache_dir,
        RESPONSE_CACHE_SEARCH_TTL_SECS,
    )
}

fn request_continuation(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    continuation: &str,
    cache_dir: Option<&Path>,
) -> Result<Value, String> {
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
) -> Result<Value, String> {
    request_youtubei_path(client, auth, bootstrap, "browse", body, cache_dir, ttl_secs)
}

fn request_youtubei_path(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    path: &str,
    body: &Value,
    cache_dir: Option<&Path>,
    ttl_secs: u64,
) -> Result<Value, String> {
    let cache_file = cache_dir
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
    let response = client
        .post(format!(
            "{YTM_ORIGIN}/youtubei/v1/{path}?alt=json&key={}",
            bootstrap.api_key
        ))
        .headers(headers)
        .json(body)
        .send()
        .map_err(|error| format!("YouTube Music {path} request failed: {error}"))?;
    let status = response.status();
    let response_body = response
        .text()
        .map_err(|error| format!("cannot read YouTube Music response: {error}"))?;
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
        return Err(format!("YouTube Music returned HTTP {status}: {message}"));
    }
    let value = serde_json::from_str(&response_body)
        .map_err(|error| format!("invalid YouTube Music response: {error}"))?;
    if let Some(cache_file) = &cache_file {
        if let Err(error) = save_response_cache(cache_file, &value, ttl_secs) {
            log_diagnostic(&format!("response-cache-write-error={error}"));
        } else if let Some(cache_dir) = cache_file.parent() {
            prune_response_cache(cache_dir);
        }
    }
    Ok(value)
}

fn request_home_continuations(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    first_response: Value,
    cache_dir: Option<&Path>,
) -> Result<Vec<Value>, String> {
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

fn base_headers(auth: &AuthConfig) -> Result<HeaderMap, String> {
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
        .ok_or_else(|| "auth file is missing cookie header".to_string())?;
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

fn insert_header(headers: &mut HeaderMap, name: &str, value: &str) -> Result<(), String> {
    let name = HeaderName::from_bytes(name.as_bytes())
        .map_err(|error| format!("invalid header name `{name}`: {error}"))?;
    let value = HeaderValue::from_str(value)
        .map_err(|error| format!("invalid value for header `{name}`: {error}"))?;
    headers.insert(name, value);
    Ok(())
}

fn authorization_header(auth: &AuthConfig, timestamp: u64) -> Result<String, String> {
    let sapisid = auth
        .cookie("__Secure-3PAPISID")
        .or_else(|| auth.cookie("SAPISID"))
        .ok_or_else(|| "auth cookie is missing SAPISID".to_string())?;
    let input = format!("{timestamp} {sapisid} {YTM_ORIGIN}");
    let digest = Sha1::digest(input.as_bytes());
    Ok(format!("SAPISIDHASH {timestamp}_{digest:x}"))
}

fn current_timestamp() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| format!("system clock error: {error}"))
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
    let mut sections = Vec::new();
    collect_sections(response, &mut sections, limit);
    if !sections.is_empty() {
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
    collect_items(response, &mut items, &mut seen, limit);
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
                },
            )]
        });
    }
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
    collect_items(response, &mut items, &mut seen, limit);
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
        "continuation": metadata.continuation
    })
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
        "/title/runs/0/text",
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
    if items.len() >= limit {
        return;
    }
    match value {
        Value::Object(object) => {
            for renderer_name in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer"] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(item) = parse_item(renderer) {
                        if seen.insert(item_dedupe_key(&item)) {
                            items.push(item);
                        }
                        return;
                    }
                }
            }
            for nested in object.values() {
                collect_items(nested, items, seen, limit);
                if items.len() >= limit {
                    break;
                }
            }
        }
        Value::Array(array) => {
            for nested in array {
                collect_items(nested, items, seen, limit);
                if items.len() >= limit {
                    break;
                }
            }
        }
        _ => {}
    }
}

fn parse_card_shelf_header(renderer: &Value) -> Option<Value> {
    let title = renderer
        .pointer("/title/runs/0/text")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .map(str::to_string)?;
    let runs = item_metadata_runs(renderer);
    let browse_endpoint = find_direct_browse_endpoint(renderer);
    let browse_id = browse_endpoint
        .as_ref()
        .map(|endpoint| endpoint.browse_id.clone());
    let browse_params = browse_endpoint
        .as_ref()
        .and_then(|endpoint| endpoint.params.clone());
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
    let kind = item_kind(browse_id.as_deref(), playlist_id.as_deref(), &runs);
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
    ]);
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
    let title = renderer
        .pointer("/title/runs/0/text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            renderer
                .pointer(
                    "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text",
                )
                .and_then(Value::as_str)
                .map(str::to_string)
        })?;
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
    ]);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn parse_card(renderer: &Value) -> Option<Value> {
    let title = renderer
        .pointer("/title/runs/0/text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            renderer
                .pointer(
                    "/flexColumns/0/musicResponsiveListItemFlexColumnRenderer/text/runs/0/text",
                )
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| {
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
    let playlist_id = find_first_string_for_key(renderer, "playlistId");
    let id = browse_id
        .clone()
        .or_else(|| playlist_id.clone())
        .unwrap_or_else(|| format!("item:{title}"));
    let kind = item_kind(browse_id.as_deref(), playlist_id.as_deref(), &runs);
    let subtitle = metadata_subtitle(&title, &metadata_runs);
    let metadata = metadata_tokens(&title, &metadata_runs);
    let thumbnail_url = find_best_thumbnail(renderer);
    let url = item_url(&kind, browse_id.as_deref(), playlist_id.as_deref());
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
    ]);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn playable_item_kind(runs: &[TextRun]) -> String {
    if text_runs_contain(runs, "episode") || text_runs_contain(runs, "podcast") {
        "episode".to_string()
    } else {
        "track".to_string()
    }
}

fn item_kind(browse_id: Option<&str>, playlist_id: Option<&str>, runs: &[TextRun]) -> String {
    if text_runs_contain(runs, "podcast") {
        return "podcast".to_string();
    }
    if text_runs_contain(runs, "episode") {
        return "episode".to_string();
    }
    if playlist_id.is_some() {
        return "playlist".to_string();
    }
    match browse_id.unwrap_or_default() {
        id if id.starts_with("MPRE") => "album",
        id if id.starts_with("MPSP") => "podcast",
        id if id.starts_with("MPED") => "episode",
        id if id.starts_with("UC") => "artist",
        id if id.starts_with("VL") || id.starts_with("PL") || id.starts_with("RD") => "playlist",
        _ => "item",
    }
    .to_string()
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
    Some(BrowseEndpoint { browse_id, params })
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
mod tests {
    use super::*;
    use crate::auth::AuthSource;
    use std::collections::BTreeMap;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_DIRECTORY_COUNTER: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn computes_sapisid_hash() {
        let auth = test_auth();
        assert_eq!(
            authorization_header(&auth, 123).unwrap(),
            "SAPISIDHASH 123_70c4da258f21d816b37d5530bd3f6cd07379c8b2"
        );
    }

    #[test]
    fn extracts_bootstrap_configuration() {
        let html = r#"<script>ytcfg.set({"INNERTUBE_API_KEY":"key","INNERTUBE_CLIENT_VERSION":"1.20260623.01.00","VISITOR_DATA":"visitor","INNERTUBE_CONTEXT":{"client":{"clientName":"WEB_REMIX","clientVersion":"old","hl":"zh-CN","gl":"US"},"user":{"lockedSafetyMode":false}}});</script>"#;
        assert_eq!(
            extract_config_string(html, "INNERTUBE_API_KEY").as_deref(),
            Some("key")
        );
        assert_eq!(
            extract_config_string(html, "VISITOR_DATA").as_deref(),
            Some("visitor")
        );
        let context = extract_config_value(html, "INNERTUBE_CONTEXT").expect("context");
        assert_eq!(
            context.pointer("/client/gl").and_then(Value::as_str),
            Some("US")
        );
        assert_eq!(
            context
                .pointer("/user/lockedSafetyMode")
                .and_then(Value::as_bool),
            Some(false)
        );
    }

    #[test]
    fn browse_id_request_body_includes_params() {
        let auth = AuthConfig {
            innertube_context: Some(json!({
                "client": {
                    "clientName": "WEB_REMIX",
                    "clientVersion": "auth-client-version",
                    "hl": "zh-CN",
                    "gl": "US"
                },
                "user": {
                    "lockedSafetyMode": false,
                    "onBehalfOfUser": "auth-brand"
                }
            })),
            ..test_auth()
        };
        let bootstrap = Bootstrap {
            api_key: "key".to_string(),
            client_version: "client-version".to_string(),
            visitor_data: None,
            context: Some(json!({
                "client": {
                    "clientName": "WEB_REMIX",
                    "clientVersion": "old-client-version",
                    "hl": "en",
                    "gl": "IN"
                },
                "user": {
                    "lockedSafetyMode": true
                }
            })),
        };
        let body = browse_id_request_body(&auth, &bootstrap, "VLPL1", Some("ggMCCAI%3D"));
        assert_eq!(body.get("browseId").and_then(Value::as_str), Some("VLPL1"));
        assert_eq!(
            body.get("params").and_then(Value::as_str),
            Some("ggMCCAI%3D")
        );
        assert_eq!(
            body.pointer("/context/client/clientVersion")
                .and_then(Value::as_str),
            Some("client-version")
        );
        assert_eq!(
            body.pointer("/context/client/hl").and_then(Value::as_str),
            Some("en")
        );
        assert_eq!(
            body.pointer("/context/client/gl").and_then(Value::as_str),
            Some("IN")
        );
        assert_eq!(
            body.pointer("/context/user/lockedSafetyMode")
                .and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            body.pointer("/context/user/onBehalfOfUser")
                .and_then(Value::as_str),
            Some("auth-brand")
        );
    }

    #[test]
    fn request_body_sets_on_behalf_of_user_from_page_id() {
        let auth = AuthConfig {
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=secret".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
                ("x-goog-pageid".to_string(), "brand-page-id".to_string()),
            ]),
            ..test_auth()
        };
        let bootstrap = Bootstrap {
            api_key: "key".to_string(),
            client_version: "client-version".to_string(),
            visitor_data: None,
            context: None,
        };
        let body = browse_id_request_body(&auth, &bootstrap, "FEmusic_home", None);
        assert_eq!(
            body.pointer("/context/user/onBehalfOfUser")
                .and_then(Value::as_str),
            Some("brand-page-id")
        );
    }

    #[test]
    fn base_headers_do_not_send_page_id_as_header() {
        let auth = AuthConfig {
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=secret".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
                ("x-goog-pageid".to_string(), "brand-page-id".to_string()),
            ]),
            ..test_auth()
        };
        let headers = base_headers(&auth).unwrap();
        assert_eq!(
            headers
                .get("x-goog-authuser")
                .and_then(|value| value.to_str().ok()),
            Some("0")
        );
        assert!(headers.get("x-goog-pageid").is_none());
    }

    #[test]
    fn bootstrap_cache_round_trips_recent_entries() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let cache_file = directory.join("bootstrap-cache.json");
        let bootstrap = Bootstrap {
            api_key: "key".to_string(),
            client_version: "client-version".to_string(),
            visitor_data: Some("visitor".to_string()),
            context: Some(json!({"client": {"hl": "en"}})),
        };

        save_bootstrap_cache(&cache_file, &bootstrap).unwrap();
        let loaded = load_bootstrap_cache(&cache_file).expect("bootstrap cache");

        assert_eq!(loaded.api_key, "key");
        assert_eq!(loaded.client_version, "client-version");
        assert_eq!(loaded.visitor_data.as_deref(), Some("visitor"));
        assert_eq!(loaded.context, Some(json!({"client": {"hl": "en"}})));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn bootstrap_cache_ignores_stale_entries() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let cache_file = directory.join("bootstrap-cache.json");
        let cache = BootstrapCache {
            schema: BOOTSTRAP_CACHE_SCHEMA_VERSION,
            fetched_at: 1,
            api_key: "key".to_string(),
            client_version: "client-version".to_string(),
            visitor_data: None,
            context: None,
        };
        fs::write(&cache_file, serde_json::to_vec(&cache).unwrap()).unwrap();

        assert!(load_bootstrap_cache(&cache_file).is_none());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn response_cache_round_trips_recent_entries() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let cache_file = directory.join("response.json");
        let value = json!({"contents": [{"title": "cached"}]});

        save_response_cache(&cache_file, &value, 60).unwrap();
        let loaded = load_response_cache(&cache_file).expect("response cache");

        assert_eq!(loaded, value);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn response_cache_ignores_stale_entries() {
        let directory = temporary_test_directory();
        fs::create_dir_all(&directory).unwrap();
        let cache_file = directory.join("response.json");
        let cache = ResponseCache {
            schema: RESPONSE_CACHE_SCHEMA_VERSION,
            fetched_at: 1,
            ttl_secs: 60,
            value: json!({"contents": []}),
        };
        fs::write(&cache_file, serde_json::to_vec(&cache).unwrap()).unwrap();

        assert!(load_response_cache(&cache_file).is_none());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn response_cache_key_is_scoped_to_auth_identity() {
        let bootstrap = Bootstrap {
            api_key: "key".to_string(),
            client_version: "client-version".to_string(),
            visitor_data: None,
            context: None,
        };
        let body = json!({
            "context": youtubei_context(&test_auth(), &bootstrap),
            "browseId": "FEmusic_home"
        });
        let first = response_cache_key(&test_auth(), &bootstrap, "browse", &body).unwrap();
        let second_auth = AuthConfig {
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=other".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
            ]),
            ..test_auth()
        };
        let second = response_cache_key(&second_auth, &bootstrap, "browse", &body).unwrap();

        assert_ne!(first, second);
    }

    #[test]
    fn appends_consent_cookie_when_missing() {
        assert_eq!(
            cookie_header_with_consent("SAPISID=secret", false),
            "SAPISID=secret; SOCS=CAI"
        );
        assert_eq!(
            cookie_header_with_consent("SAPISID=secret; SOCS=present", true),
            "SAPISID=secret; SOCS=present"
        );
    }

    #[test]
    fn normalizes_music_renderers() {
        let response = json!({
            "contents": [{
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [
                        {"musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{
                                "text": "Song",
                                "navigationEndpoint": {"watchEndpoint": {"videoId": "v1"}}
                            }]}
                        }},
                        {"musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [
                                {"text": "Artist", "navigationEndpoint": {
                                    "browseEndpoint": {"browseId": "UC1"}
                                }},
                                {"text": " • "},
                                {"text": "Album", "navigationEndpoint": {
                                    "browseEndpoint": {"browseId": "MPRE1"}
                                }}
                            ]}
                        }}
                    ],
                    "fixedColumns": [{"musicResponsiveListItemFixedColumnRenderer": {
                        "text": {"runs": [{"text": "3:30"}]}
                    }}],
                    "thumbnail": {"musicThumbnailRenderer": {
                        "thumbnail": {"thumbnails": [{"url": "small"}, {"url": "large"}]}
                    }}
                }
            }]
        });
        let normalized = normalize_response(&BrowseTarget::Library, 10, &response);
        let track = normalized.pointer("/sources/0/items/0").unwrap();
        assert_eq!(track.get("id").and_then(Value::as_str), Some("v1"));
        assert_eq!(track.get("artist").and_then(Value::as_str), Some("Artist"));
        assert_eq!(track.get("album").and_then(Value::as_str), Some("Album"));
        assert_eq!(track.get("duration").and_then(Value::as_u64), Some(210));
        assert_eq!(
            track.get("thumbnail-url").and_then(Value::as_str),
            Some("large")
        );
    }

    #[test]
    fn preserves_non_track_music_cards() {
        let response = json!({
            "contents": [{
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Album Title",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "MPRE1", "params": "album-params"}
                        }
                    }]},
                    "subtitle": {"runs": [{"text": "Artist"}]},
                    "thumbnailRenderer": {"musicThumbnailRenderer": {
                        "thumbnail": {"thumbnails": [{"url": "album-small"}, {"url": "album-large"}]}
                    }}
                }
            }, {
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Playlist Title",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "VLPL1", "params": "playlist-params"}
                        }
                    }]},
                    "subtitle": {"runs": [{
                        "text": "Artist",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "UCARTIST"}
                        }
                    }]},
                    "thumbnailRenderer": {"musicThumbnailRenderer": {
                        "thumbnail": {"thumbnails": [{"url": "playlist"}]}
                    }}
                }
            }]
        });
        let normalized = normalize_response(&BrowseTarget::Home, 10, &response);
        let album = normalized.pointer("/sources/0/items/0").unwrap();
        let playlist = normalized.pointer("/sources/0/items/1").unwrap();
        assert_eq!(album.get("type").and_then(Value::as_str), Some("album"));
        assert_eq!(
            album.get("url").and_then(Value::as_str),
            Some("https://music.youtube.com/browse/MPRE1")
        );
        assert_eq!(
            album.get("browse-id").and_then(Value::as_str),
            Some("MPRE1")
        );
        assert_eq!(
            album.get("browse-params").and_then(Value::as_str),
            Some("album-params")
        );
        assert_eq!(
            album.get("thumbnail-url").and_then(Value::as_str),
            Some("album-large")
        );
        assert_eq!(
            playlist.get("type").and_then(Value::as_str),
            Some("playlist")
        );
        assert_eq!(
            playlist.get("browse-id").and_then(Value::as_str),
            Some("VLPL1")
        );
        assert_eq!(
            playlist.get("browse-params").and_then(Value::as_str),
            Some("playlist-params")
        );
    }

    #[test]
    fn normalizes_home_shelves_as_sources() {
        let response = json!({
            "contents": {
                "singleColumnBrowseResultsRenderer": {
                    "tabs": [{
                        "tabRenderer": {
                            "content": {
                                "sectionListRenderer": {
                                    "contents": [{
                                        "musicCarouselShelfRenderer": {
                                            "header": {
                                                "musicCarouselShelfBasicHeaderRenderer": {
                                                    "title": {"runs": [{"text": "Listen again"}]}
                                                }
                                            },
                                            "contents": [{
                                                "musicTwoRowItemRenderer": {
                                                    "title": {"runs": [{"text": "Song A"}]},
                                                    "navigationEndpoint": {
                                                        "watchEndpoint": {"videoId": "a1"}
                                                    },
                                                    "subtitle": {"runs": [{"text": "Artist A"}]}
                                                }
                                            }]
                                        }
                                    }, {
                                        "musicCarouselShelfRenderer": {
                                            "header": {
                                                "musicCarouselShelfBasicHeaderRenderer": {
                                                    "title": {"runs": [{"text": "Mixed for you"}]}
                                                }
                                            },
                                            "contents": [{
                                                "musicTwoRowItemRenderer": {
                                                    "title": {"runs": [{"text": "Playlist B"}]},
                                                    "navigationEndpoint": {
                                                        "browseEndpoint": {"browseId": "VLPL2"}
                                                    }
                                                }
                                            }]
                                        }
                                    }]
                                }
                            }
                        }
                    }]
                }
            }
        });
        let normalized = normalize_response(&BrowseTarget::Home, 12, &response);
        let sources = normalized
            .get("sources")
            .and_then(Value::as_array)
            .expect("sources");
        assert_eq!(sources.len(), 2);
        assert_eq!(
            sources[0].get("title").and_then(Value::as_str),
            Some("Listen again")
        );
        assert_eq!(
            sources[1].get("title").and_then(Value::as_str),
            Some("Mixed for you")
        );
        assert_eq!(
            sources[0].pointer("/items/0/type").and_then(Value::as_str),
            Some("track")
        );
        assert_eq!(
            sources[1].pointer("/items/0/type").and_then(Value::as_str),
            Some("playlist")
        );
    }

    #[test]
    fn normalizes_home_from_primary_tab_only() {
        let response = json!({
            "contents": {
                "singleColumnBrowseResultsRenderer": {
                    "tabs": [{
                        "tabRenderer": {
                            "selected": true,
                            "content": {
                                "sectionListRenderer": {
                                    "contents": [{
                                        "musicCarouselShelfRenderer": {
                                            "header": {
                                                "musicCarouselShelfBasicHeaderRenderer": {
                                                    "title": {"runs": [{"text": "Listen again"}]}
                                                }
                                            },
                                            "contents": [{
                                                "musicTwoRowItemRenderer": {
                                                    "title": {"runs": [{"text": "Personal Song"}]},
                                                    "navigationEndpoint": {
                                                        "watchEndpoint": {"videoId": "personal"}
                                                    }
                                                }
                                            }]
                                        }
                                    }]
                                }
                            }
                        }
                    }, {
                        "tabRenderer": {
                            "content": {
                                "sectionListRenderer": {
                                    "contents": [{
                                        "musicCarouselShelfRenderer": {
                                            "header": {
                                                "musicCarouselShelfBasicHeaderRenderer": {
                                                    "title": {"runs": [{"text": "Regional charts"}]}
                                                }
                                            },
                                            "contents": [{
                                                "musicTwoRowItemRenderer": {
                                                    "title": {"runs": [{"text": "Generic Playlist"}]},
                                                    "navigationEndpoint": {
                                                        "browseEndpoint": {"browseId": "VLGENERIC"}
                                                    }
                                                }
                                            }]
                                        }
                                    }]
                                }
                            }
                        }
                    }]
                }
            }
        });
        let normalized = normalize_response(&BrowseTarget::Home, 12, &response);
        let sources = normalized
            .get("sources")
            .and_then(Value::as_array)
            .expect("sources");
        assert_eq!(sources.len(), 1);
        assert_eq!(
            sources[0].get("title").and_then(Value::as_str),
            Some("Listen again")
        );
        assert_eq!(
            sources[0].pointer("/items/0/id").and_then(Value::as_str),
            Some("personal")
        );
    }

    #[test]
    fn normalizes_library_shelves_as_sources() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Albums"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Album A"}]},
                                    "navigationEndpoint": {
                                        "browseEndpoint": {"browseId": "MPRE1"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let normalized = normalize_response(&BrowseTarget::Library, 12, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("kind").and_then(Value::as_str),
            Some("youtube-music-library-section")
        );
        assert_eq!(source.get("title").and_then(Value::as_str), Some("Albums"));
        assert_eq!(
            source.pointer("/items/0/type").and_then(Value::as_str),
            Some("album")
        );
    }

    #[test]
    fn library_targets_keep_display_order() {
        assert_eq!(
            LIBRARY_TARGETS,
            [
                BrowseTarget::LibrarySongs,
                BrowseTarget::LibraryAlbums,
                BrowseTarget::LibraryArtists,
                BrowseTarget::LibraryPlaylists,
                BrowseTarget::Liked,
            ]
        );
    }

    #[test]
    fn normalizes_explore_shelves_as_sources() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "New releases"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Album A"}]},
                                    "navigationEndpoint": {
                                        "browseEndpoint": {"browseId": "MPRE1"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let normalized = normalize_response(&BrowseTarget::Explore, 12, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("kind").and_then(Value::as_str),
            Some("youtube-music-explore-section")
        );
        assert_eq!(
            source.get("id").and_then(Value::as_str),
            Some("ytm:explore:1:new-releases")
        );
        assert_eq!(
            source.pointer("/items/0/type").and_then(Value::as_str),
            Some("album")
        );
    }

    #[test]
    fn normalizes_search_response() {
        let response = json!({
            "contents": [{
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [{
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{"text": "Tokyo"}]}
                        }
                    }],
                    "navigationEndpoint": {
                        "watchEndpoint": {"videoId": "v1"}
                    }
                }
            }, {
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Album Result",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "MPRE1"}
                        }
                    }]},
                    "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "Artist"}]},
                    "thumbnailOverlay": {
                        "musicItemThumbnailOverlayRenderer": {
                            "content": {
                                "musicPlayButtonRenderer": {
                                    "playNavigationEndpoint": {
                                        "watchEndpoint": {"videoId": "nested-play-button"}
                                    }
                                }
                            }
                        }
                    }
                }
            }, {
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [{
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{
                                "text": "Artist Result",
                                "navigationEndpoint": {
                                    "browseEndpoint": {"browseId": "UC1"}
                                }
                            }]}
                        }
                    }],
                    "navigationEndpoint": {
                        "browseEndpoint": {"browseId": "UC1"}
                    }
                }
            }, {
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Podcast Result",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "MPSP1"}
                        }
                    }]},
                    "subtitle": {"runs": [{"text": "Podcast"}]}
                }
            }, {
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [{
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{"text": "Episode Result"}]}
                        }
                    }, {
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{"text": "Episode"}, {"text": " • "}, {"text": "Podcast"}]}
                        }
                    }],
                    "navigationEndpoint": {
                        "watchEndpoint": {"videoId": "episode1"}
                    }
                }
            }]
        });
        let normalized = normalize_search_response("lofi tokyo", 10, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("kind").and_then(Value::as_str),
            Some("youtube-music-search")
        );
        assert_eq!(
            source.get("url").and_then(Value::as_str),
            Some("https://music.youtube.com/search?q=lofi+tokyo")
        );
        assert_eq!(
            source.pointer("/items/0/id").and_then(Value::as_str),
            Some("v1")
        );
        assert_eq!(
            source.pointer("/items/0/type").and_then(Value::as_str),
            Some("track")
        );
        assert_eq!(
            source.pointer("/items/1/type").and_then(Value::as_str),
            Some("album")
        );
        assert_eq!(
            source.pointer("/items/1/id").and_then(Value::as_str),
            Some("MPRE1")
        );
        assert_eq!(
            source.pointer("/items/2/type").and_then(Value::as_str),
            Some("artist")
        );
        assert_eq!(
            source.pointer("/items/3/type").and_then(Value::as_str),
            Some("podcast")
        );
        assert_eq!(
            source.pointer("/items/4/type").and_then(Value::as_str),
            Some("episode")
        );
    }

    #[test]
    fn normalizes_card_subtitle_without_menu_actions() {
        let response = json!({
            "contents": [{
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Nella Fantasia",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "MPRE1"}
                        }
                    }]},
                    "subtitle": {"runs": [
                        {"text": "Single"},
                        {"text": " • "},
                        {"text": "Allan Palacios Chan & Tina Guo"},
                        {"text": "Shuffle play"},
                        {"text": "Start mix"},
                        {"text": "Album added to queue"},
                        {"text": "Save album to library"},
                        {"text": "Remove album from library"},
                        {"text": "Album will play next"},
                        {"text": "Play next"}
                    ]}
                }
            }]
        });
        let normalized = normalize_search_response("nella fantasia", 10, &response);
        assert_eq!(
            normalized
                .pointer("/sources/0/items/0/subtitle")
                .and_then(Value::as_str),
            Some("Single - Allan Palacios Chan & Tina Guo")
        );
    }

    #[test]
    fn normalizes_playlist_subtitle_without_menu_actions() {
        let response = json!({
            "contents": [{
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Lofi Loft",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "VLPL1"}
                        }
                    }]},
                    "subtitle": {"runs": [
                        {"text": "Playlist"},
                        {"text": " • "},
                        {"text": "Evil Needle"},
                        {"text": "Playlist added to queue"},
                        {"text": "Save playlist to library"},
                        {"text": "Remove playlist from library"},
                        {"text": "Save to playlist"},
                        {"text": "Playlist will play next"},
                        {"text": "Play next"}
                    ]}
                }
            }]
        });
        let normalized = normalize_search_response("lofi loft", 10, &response);
        assert_eq!(
            normalized
                .pointer("/sources/0/items/0/subtitle")
                .and_then(Value::as_str),
            Some("Playlist - Evil Needle")
        );
    }

    #[test]
    fn normalizes_album_subtitle_with_clickable_artists() {
        let response = json!({
            "contents": [{
                "musicTwoRowItemRenderer": {
                    "title": {"runs": [{
                        "text": "Smoke Rings",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "MPRE1"}
                        }
                    }]},
                    "subtitle": {"runs": [
                        {"text": "Album"},
                        {"text": " • "},
                        {"text": "Kolisnik", "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "UCKOL", "params": "kolisnik-params"}
                        }},
                        {"text": " & "},
                        {"text": "LoFi Beats", "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "UCLOFI"}
                        }},
                        {"text": "Album added to queue"},
                        {"text": "Save album to library"},
                        {"text": "Remove album from library"}
                    ]}
                }
            }]
        });
        let normalized = normalize_search_response("smoke rings", 10, &response);
        let item = normalized.pointer("/sources/0/items/0").unwrap();
        assert_eq!(
            item.get("subtitle").and_then(Value::as_str),
            Some("Album - Kolisnik & LoFi Beats")
        );
        assert_eq!(
            item.pointer("/metadata/1/text").and_then(Value::as_str),
            Some(" - Kolisnik")
        );
        assert_eq!(
            item.pointer("/metadata/1/browse-id")
                .and_then(Value::as_str),
            Some("UCKOL")
        );
        assert_eq!(
            item.pointer("/metadata/1/browse-params")
                .and_then(Value::as_str),
            Some("kolisnik-params")
        );
        assert_eq!(
            item.pointer("/metadata/3/text").and_then(Value::as_str),
            Some("LoFi Beats")
        );
        assert_eq!(
            item.pointer("/metadata/3/browse-id")
                .and_then(Value::as_str),
            Some("UCLOFI")
        );
    }

    #[test]
    fn normalizes_search_card_shelf_as_top_result_section() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCardShelfRenderer": {
                            "title": {"runs": [{
                                "text": "Chill girl Vibes",
                                "navigationEndpoint": {
                                    "browseEndpoint": {"browseId": "UCCHILL", "params": "artist-params"}
                                }
                            }]},
                            "subtitle": {"runs": [
                                {"text": "Artist"},
                                {"text": " • "},
                                {"text": "448K monthly listeners"}
                            ]},
                            "thumbnail": {"musicThumbnailRenderer": {
                                "thumbnail": {"thumbnails": [{"url": "artist-small"}, {"url": "artist-large"}]}
                            }},
                            "contents": [{
                                "musicResponsiveListItemRenderer": {
                                    "flexColumns": [{
                                        "musicResponsiveListItemFlexColumnRenderer": {
                                            "text": {"runs": [{"text": "Quiet Collar Mark"}]}
                                        }
                                    }, {
                                        "musicResponsiveListItemFlexColumnRenderer": {
                                            "text": {"runs": [
                                                {"text": "Song"},
                                                {"text": " • "},
                                                {"text": "Chill girl Vibes"}
                                            ]}
                                        }
                                    }],
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "song1"}
                                    },
                                    "thumbnail": {"musicThumbnailRenderer": {
                                        "thumbnail": {"thumbnails": [{"url": "song-thumb"}]}
                                    }}
                                }
                            }]
                        }
                    }, {
                        "musicShelfRenderer": {
                            "title": {"runs": [{"text": "Songs"}]},
                            "contents": [{
                                "musicResponsiveListItemRenderer": {
                                    "flexColumns": [{
                                        "musicResponsiveListItemFlexColumnRenderer": {
                                            "text": {"runs": [{"text": "Corner Store"}]}
                                        }
                                    }],
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "song2"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let normalized = normalize_search_response("chill girl vibes", 10, &response);
        let sources = normalized
            .get("sources")
            .and_then(Value::as_array)
            .expect("sources");
        assert_eq!(sources.len(), 2);
        assert_eq!(
            sources[0].get("kind").and_then(Value::as_str),
            Some("youtube-music-search-section")
        );
        assert_eq!(
            sources[0].get("title").and_then(Value::as_str),
            Some("Top result")
        );
        assert_eq!(
            sources[0].pointer("/items/0/type").and_then(Value::as_str),
            Some("artist")
        );
        assert_eq!(
            sources[0].pointer("/items/0/title").and_then(Value::as_str),
            Some("Chill girl Vibes")
        );
        assert_eq!(
            sources[0]
                .pointer("/items/0/subtitle")
                .and_then(Value::as_str),
            Some("Artist - 448K monthly listeners")
        );
        assert_eq!(
            sources[0]
                .pointer("/items/0/browse-id")
                .and_then(Value::as_str),
            Some("UCCHILL")
        );
        assert_eq!(
            sources[0]
                .pointer("/items/0/browse-params")
                .and_then(Value::as_str),
            Some("artist-params")
        );
        assert_eq!(
            sources[0]
                .pointer("/items/0/thumbnail-url")
                .and_then(Value::as_str),
            Some("artist-large")
        );
        assert_eq!(
            sources[0].pointer("/items/1/type").and_then(Value::as_str),
            Some("track")
        );
        assert_eq!(
            sources[1].get("title").and_then(Value::as_str),
            Some("Songs")
        );
    }

    #[test]
    fn normalizes_browse_id_response_as_detail_source() {
        let response = json!({
            "header": {
                "musicDetailHeaderRenderer": {
                    "title": {"runs": [{"text": "Playlist Title"}]}
                }
            },
            "contents": [{
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [{
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{"text": "Song"}]}
                        }
                    }],
                    "navigationEndpoint": {
                        "watchEndpoint": {"videoId": "v1"}
                    }
                }
            }]
        });
        let normalized = normalize_browse_id_response("VLPL1", 10, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("kind").and_then(Value::as_str),
            Some("youtube-music-playlist")
        );
        assert_eq!(
            source.get("title").and_then(Value::as_str),
            Some("Playlist Title")
        );
        assert_eq!(
            source.pointer("/items/0/id").and_then(Value::as_str),
            Some("v1")
        );
    }

    #[test]
    fn normalizes_browse_id_response_without_internal_title() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": []
                }
            }
        });
        let normalized = normalize_browse_id_response("VLPL1", 10, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("kind").and_then(Value::as_str),
            Some("youtube-music-playlist")
        );
        assert_eq!(
            source.get("title").and_then(Value::as_str),
            Some("Playlist")
        );
    }

    #[test]
    fn normalizes_browse_id_response_visual_header_title() {
        let response = json!({
            "header": {
                "musicVisualHeaderRenderer": {
                    "title": {"runs": [{"text": "Visual Album"}]}
                }
            },
            "contents": {
                "sectionListRenderer": {
                    "contents": []
                }
            }
        });
        let normalized = normalize_browse_id_response("MPRE1", 10, &response);
        let source = normalized.pointer("/sources/0").unwrap();
        assert_eq!(
            source.get("title").and_then(Value::as_str),
            Some("Visual Album")
        );
    }

    #[test]
    fn normalizes_browse_id_response_with_header_and_sections() {
        let response = json!({
            "header": {
                "musicImmersiveHeaderRenderer": {
                    "title": {"runs": [{"text": "Chill girl Vibes"}]},
                    "subtitle": {"runs": [
                        {"text": "1.2K subscribers"},
                        {"text": "More"},
                        {"text": "Less"},
                        {"text": "Mix"},
                        {"text": "Subscribe"},
                        {"text": "Unsubscribe"},
                        {"text": "Unsubscribe from"},
                        {"text": "?"},
                        {"text": "85"}
                    ]},
                    "thumbnail": {"musicThumbnailRenderer": {
                        "thumbnail": {"thumbnails": [{"url": "avatar-small"}, {"url": "avatar-large"}]}
                    }}
                }
            },
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicShelfRenderer": {
                            "title": {"runs": [{"text": "Songs"}]},
                            "contents": [{
                                "musicResponsiveListItemRenderer": {
                                    "flexColumns": [{
                                        "musicResponsiveListItemFlexColumnRenderer": {
                                            "text": {"runs": [{"text": "Popular Song"}]}
                                        }
                                    }],
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "song1"}
                                    }
                                }
                            }]
                        }
                    }, {
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Albums"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{
                                        "text": "Album A",
                                        "navigationEndpoint": {
                                            "browseEndpoint": {"browseId": "MPRE1"}
                                        }
                                    }]}
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let normalized = normalize_browse_id_response("UCartist", 10, &response);
        let sources = normalized
            .get("sources")
            .and_then(Value::as_array)
            .expect("sources");
        assert_eq!(sources.len(), 3);
        assert_eq!(
            sources[0].get("kind").and_then(Value::as_str),
            Some("youtube-music-artist")
        );
        assert_eq!(
            sources[0].get("title").and_then(Value::as_str),
            Some("Chill girl Vibes")
        );
        assert_eq!(
            sources[0].get("subtitle").and_then(Value::as_str),
            Some("1.2K subscribers")
        );
        assert_eq!(
            sources[0].get("thumbnail-url").and_then(Value::as_str),
            Some("avatar-large")
        );
        assert_eq!(
            sources[1].get("title").and_then(Value::as_str),
            Some("Songs")
        );
        assert_eq!(
            sources[1].pointer("/items/0/type").and_then(Value::as_str),
            Some("track")
        );
        assert_eq!(
            sources[2].get("title").and_then(Value::as_str),
            Some("Albums")
        );
        assert_eq!(
            sources[2].pointer("/items/0/type").and_then(Value::as_str),
            Some("album")
        );
    }

    #[test]
    fn finds_home_continuation_from_section_list() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Listen again"}]}
                                }
                            },
                            "contents": []
                        }
                    }, {
                        "continuationItemRenderer": {
                            "continuationEndpoint": {
                                "continuationCommand": {"token": "next-page"}
                            }
                        }
                    }]
                }
            }
        });
        assert_eq!(
            find_home_continuation(&response).as_deref(),
            Some("next-page")
        );
    }

    #[test]
    fn normalizes_home_response_with_top_level_continuation() {
        let response = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Listen again"}]}
                                }
                            },
                            "contents": []
                        }
                    }, {
                        "continuationItemRenderer": {
                            "continuationEndpoint": {
                                "continuationCommand": {"token": "next-page"}
                            }
                        }
                    }]
                }
            }
        });
        let normalized = normalize_home_responses(12, &[response]);
        assert_eq!(
            normalized.get("continuation").and_then(Value::as_str),
            Some("next-page")
        );
    }

    #[test]
    fn normalizes_home_continuation_responses_together() {
        let first = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Listen again"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Song A"}]},
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "a1"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let continuation = json!({
            "onResponseReceivedActions": [{
                "appendContinuationItemsAction": {
                    "continuationItems": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Made for you"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Playlist B"}]},
                                    "navigationEndpoint": {
                                        "browseEndpoint": {"browseId": "VLPL2"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }]
        });
        let normalized = normalize_home_responses(12, &[first, continuation]);
        let sources = normalized
            .get("sources")
            .and_then(Value::as_array)
            .expect("sources");
        assert_eq!(sources.len(), 2);
        assert_eq!(
            sources[0].get("title").and_then(Value::as_str),
            Some("Listen again")
        );
        assert_eq!(
            sources[1].get("title").and_then(Value::as_str),
            Some("Made for you")
        );
    }

    #[test]
    fn normalizes_home_continuation_with_distinct_source_ids() {
        let first = json!({
            "contents": {
                "sectionListRenderer": {
                    "contents": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Listen again"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Song A"}]},
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "a1"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }
        });
        let continuation = json!({
            "onResponseReceivedActions": [{
                "appendContinuationItemsAction": {
                    "continuationItems": [{
                        "musicCarouselShelfRenderer": {
                            "header": {
                                "musicCarouselShelfBasicHeaderRenderer": {
                                    "title": {"runs": [{"text": "Listen again"}]}
                                }
                            },
                            "contents": [{
                                "musicTwoRowItemRenderer": {
                                    "title": {"runs": [{"text": "Song B"}]},
                                    "navigationEndpoint": {
                                        "watchEndpoint": {"videoId": "b1"}
                                    }
                                }
                            }]
                        }
                    }]
                }
            }]
        });
        let first_sources = normalize_home_responses(12, &[first]);
        let more_sources = normalize_home_continuation_response("next-page", 12, &continuation);
        let first_id = first_sources
            .pointer("/sources/0/id")
            .and_then(Value::as_str)
            .expect("first id");
        let more_id = more_sources
            .pointer("/sources/0/id")
            .and_then(Value::as_str)
            .expect("more id");
        assert_ne!(first_id, more_id);
        assert!(more_id.starts_with("ytm:home:more:"));
    }

    fn test_auth() -> AuthConfig {
        AuthConfig {
            schema: 1,
            source: AuthSource {
                kind: "login-window".to_string(),
                browser: Some("test".to_string()),
            },
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=secret".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
            ]),
            innertube_context: None,
        }
    }

    fn temporary_test_directory() -> std::path::PathBuf {
        let counter = TEST_DIRECTORY_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "ytm-radio-ytmusic-test-{}-{nanos}-{counter}",
            std::process::id()
        ))
    }
}
