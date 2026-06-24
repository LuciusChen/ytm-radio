use crate::auth::AuthConfig;
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, CONTENT_TYPE, ORIGIN, USER_AGENT};
use serde_json::{json, Map, Value};
use sha1::{Digest, Sha1};
use std::collections::HashSet;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

const YTM_ORIGIN: &str = "https://music.youtube.com";
const HOME_CONTINUATION_PAGE_LIMIT: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowseTarget {
    Home,
    Library,
    Liked,
}

pub fn browse(target: &BrowseTarget, limit: usize, auth: &AuthConfig) -> Result<Value, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| format!("cannot create HTTP client: {error}"))?;
    let bootstrap = bootstrap(&client, auth)?;
    let response = request_browse(&client, auth, &bootstrap, target)?;
    if matches!(target, BrowseTarget::Home) {
        let responses = request_home_continuations(&client, auth, &bootstrap, response)?;
        Ok(normalize_home_responses(limit, &responses))
    } else {
        Ok(normalize_single_source_response(target, limit, &response))
    }
}

struct Bootstrap {
    api_key: String,
    client_version: String,
    visitor_data: Option<String>,
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
    })
}

fn request_browse(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    target: &BrowseTarget,
) -> Result<Value, String> {
    let browse_id = match target {
        BrowseTarget::Home => "FEmusic_home",
        BrowseTarget::Library => "FEmusic_liked_videos",
        BrowseTarget::Liked => "VLLM",
    };
    let body = json!({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": bootstrap.client_version,
                "hl": "en"
            },
            "user": {}
        },
        "browseId": browse_id
    });
    request_youtubei(client, auth, bootstrap, &body)
}

fn request_continuation(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    continuation: &str,
) -> Result<Value, String> {
    let body = json!({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": bootstrap.client_version,
                "hl": "en"
            },
            "user": {}
        },
        "continuation": continuation
    });
    request_youtubei(client, auth, bootstrap, &body)
}

fn request_youtubei(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    body: &Value,
) -> Result<Value, String> {
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
    let response = client
        .post(format!(
            "{YTM_ORIGIN}/youtubei/v1/browse?alt=json&key={}",
            bootstrap.api_key
        ))
        .headers(headers)
        .json(body)
        .send()
        .map_err(|error| format!("YouTube Music browse request failed: {error}"))?;
    let status = response.status();
    let response_body = response
        .text()
        .map_err(|error| format!("cannot read YouTube Music response: {error}"))?;
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
    serde_json::from_str(&response_body)
        .map_err(|error| format!("invalid YouTube Music response: {error}"))
}

fn request_home_continuations(
    client: &Client,
    auth: &AuthConfig,
    bootstrap: &Bootstrap,
    first_response: Value,
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
        responses.push(request_continuation(client, auth, bootstrap, &token)?);
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
    headers.insert(ORIGIN, HeaderValue::from_static(YTM_ORIGIN));
    insert_header(
        &mut headers,
        "cookie",
        auth.header("cookie")
            .ok_or_else(|| "auth file is missing cookie header".to_string())?,
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

fn extract_config_string(html: &str, key: &str) -> Option<String> {
    let marker = format!("\"{key}\":");
    let start = html.find(&marker)? + marker.len();
    let remaining = html[start..].trim_start();
    let mut escaped = false;
    let mut end = None;
    for (index, character) in remaining.char_indices().skip(1) {
        match character {
            '"' if !escaped => {
                end = Some(index + 1);
                break;
            }
            '\\' if !escaped => escaped = true,
            _ => escaped = false,
        }
    }
    serde_json::from_str(&remaining[..end?]).ok()
}

#[cfg(test)]
fn normalize_response(target: &BrowseTarget, limit: usize, response: &Value) -> Value {
    if matches!(target, BrowseTarget::Home) {
        return normalize_home_response(limit, response);
    }
    normalize_single_source_response(target, limit, response)
}

#[cfg(test)]
fn normalize_home_response(limit: usize, response: &Value) -> Value {
    normalize_home_responses(limit, std::slice::from_ref(response))
}

fn normalize_home_responses(limit: usize, responses: &[Value]) -> Value {
    let mut sections = Vec::new();
    for response in responses {
        collect_sections(response, &mut sections, limit);
    }
    let sources: Vec<Value> = if sections.is_empty() {
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        for response in responses {
            collect_items(response, &mut items, &mut seen, limit);
        }
        vec![normalized_source(
            "ytm:home".to_string(),
            "youtube-music-home",
            "YouTube Music Home".to_string(),
            "https://music.youtube.com/",
            items,
            responses.last().and_then(find_home_continuation),
        )]
    } else {
        sections
            .into_iter()
            .enumerate()
            .map(|(index, section)| {
                normalized_source(
                    home_section_id(&section.title, index + 1),
                    "youtube-music-home-section",
                    section.title,
                    "https://music.youtube.com/",
                    section.items,
                    section.continuation,
                )
            })
            .collect()
    };
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
        BrowseTarget::Library => (
            "ytm:library:songs",
            "youtube-music-library",
            "Library Songs",
            "https://music.youtube.com/library/songs",
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

fn normalized_source(
    id: String,
    kind: &str,
    title: String,
    url: &str,
    items: Vec<Value>,
    continuation: Option<String>,
) -> Value {
    json!({
        "id": id,
        "kind": kind,
        "title": title,
        "url": url,
        "items": items,
        "continuation": continuation
    })
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
                "musicCarouselShelfRenderer",
                "musicShelfRenderer",
                "gridRenderer",
            ] {
                if let Some(renderer) = object.get(renderer_name) {
                    if let Some(section) = parse_section(renderer, sections.len() + 1, limit) {
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

fn home_section_id(title: &str, index: usize) -> String {
    let slug = slugify(title);
    if slug.is_empty() {
        format!("ytm:home:{index}:{}", short_hash(title))
    } else {
        format!("ytm:home:{index}:{slug}")
    }
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

fn item_dedupe_key(item: &Value) -> String {
    item.get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| item.get("title").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string()
}

fn parse_item(renderer: &Value) -> Option<Value> {
    parse_track(renderer).or_else(|| parse_card(renderer))
}

fn parse_track(renderer: &Value) -> Option<Value> {
    let video_id = find_first_string_for_key(renderer, "videoId")?;
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
                    run.text != title
                        && !is_separator(&run.text)
                        && parse_duration(&run.text).is_none()
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
    let thumbnail_url = find_best_thumbnail(renderer);
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
    let browse_id = find_first_string_for_key(renderer, "browseId");
    let playlist_id = find_first_string_for_key(renderer, "playlistId");
    let id = browse_id
        .clone()
        .or_else(|| playlist_id.clone())
        .unwrap_or_else(|| format!("item:{title}"));
    let kind = item_kind(browse_id.as_deref(), playlist_id.as_deref());
    let subtitle = runs
        .iter()
        .filter_map(|run| {
            let text = run.text.trim();
            (!text.is_empty()
                && text != title
                && !is_separator(text)
                && parse_duration(text).is_none())
            .then_some(text.to_string())
        })
        .take(4)
        .collect::<Vec<_>>()
        .join(" - ");
    let thumbnail_url = find_best_thumbnail(renderer);
    let url = item_url(&kind, browse_id.as_deref(), playlist_id.as_deref());
    let mut item = Map::from_iter([
        ("type".to_string(), Value::String(kind)),
        ("id".to_string(), Value::String(id)),
        ("title".to_string(), Value::String(title)),
        (
            "subtitle".to_string(),
            if subtitle.is_empty() {
                Value::Null
            } else {
                Value::String(subtitle)
            },
        ),
        (
            "url".to_string(),
            url.map(Value::String).unwrap_or(Value::Null),
        ),
        (
            "thumbnail-url".to_string(),
            thumbnail_url.map(Value::String).unwrap_or(Value::Null),
        ),
    ]);
    Some(Value::Object(std::mem::take(&mut item)))
}

fn item_kind(browse_id: Option<&str>, playlist_id: Option<&str>) -> String {
    if playlist_id.is_some() {
        return "playlist".to_string();
    }
    match browse_id.unwrap_or_default() {
        id if id.starts_with("MPRE") => "album",
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

#[derive(Debug)]
struct TextRun {
    text: String,
    browse_id: Option<String>,
}

fn collect_text_runs(value: &Value) -> Vec<TextRun> {
    let mut output = Vec::new();
    collect_text_runs_into(value, &mut output);
    output
}

fn collect_text_runs_into(value: &Value, output: &mut Vec<TextRun>) {
    match value {
        Value::Object(object) => {
            if let Some(text) = object.get("text").and_then(Value::as_str) {
                output.push(TextRun {
                    text: text.to_string(),
                    browse_id: object
                        .get("navigationEndpoint")
                        .and_then(|value| value.get("browseEndpoint"))
                        .and_then(|value| value.get("browseId"))
                        .and_then(Value::as_str)
                        .map(str::to_string),
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
        let html = r#"<script>ytcfg.set({"INNERTUBE_API_KEY":"key","INNERTUBE_CLIENT_VERSION":"1.20260623.01.00","VISITOR_DATA":"visitor"});</script>"#;
        assert_eq!(
            extract_config_string(html, "INNERTUBE_API_KEY").as_deref(),
            Some("key")
        );
        assert_eq!(
            extract_config_string(html, "VISITOR_DATA").as_deref(),
            Some("visitor")
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
                            "browseEndpoint": {"browseId": "MPRE1"}
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
                            "browseEndpoint": {"browseId": "VLPL1"}
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
            album.get("thumbnail-url").and_then(Value::as_str),
            Some("album-large")
        );
        assert_eq!(
            playlist.get("type").and_then(Value::as_str),
            Some("playlist")
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

    fn test_auth() -> AuthConfig {
        AuthConfig {
            schema: 1,
            source: AuthSource {
                kind: "browser".to_string(),
                browser: Some("test".to_string()),
            },
            headers: BTreeMap::from([
                ("cookie".to_string(), "__Secure-3PAPISID=secret".to_string()),
                ("origin".to_string(), YTM_ORIGIN.to_string()),
            ]),
        }
    }
}
