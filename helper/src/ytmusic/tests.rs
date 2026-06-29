// SPDX-License-Identifier: GPL-3.0-or-later

use super::*;
use crate::auth::AuthSource;
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

static TEST_DIRECTORY_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug)]
struct TestSourceError;

impl fmt::Display for TestSourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "inner cause")
    }
}

impl Error for TestSourceError {}

#[derive(Debug)]
struct TestOuterError {
    source: TestSourceError,
}

impl fmt::Display for TestOuterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "outer error")
    }
}

impl Error for TestOuterError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.source)
    }
}

fn detail_response(header: Value, sections: Vec<Value>) -> Value {
    json!({
        "header": header,
        "contents": {
            "twoColumnBrowseResultsRenderer": {
                "secondaryContents": {
                    "sectionListRenderer": {
                        "contents": sections
                    }
                }
            }
        }
    })
}

fn song_shelf(
    shelf_title: &str,
    song_title: &str,
    video_id: &str,
    playlist_id: Option<&str>,
) -> Value {
    let mut watch_endpoint =
        Map::from_iter([("videoId".to_string(), Value::String(video_id.to_string()))]);
    if let Some(playlist_id) = playlist_id {
        watch_endpoint.insert(
            "playlistId".to_string(),
            Value::String(playlist_id.to_string()),
        );
    }
    json!({
        "musicShelfRenderer": {
            "title": {"runs": [{"text": shelf_title}]},
            "contents": [{
                "musicResponsiveListItemRenderer": {
                    "flexColumns": [{
                        "musicResponsiveListItemFlexColumnRenderer": {
                            "text": {"runs": [{
                                "text": song_title,
                                "navigationEndpoint": {
                                    "watchEndpoint": watch_endpoint
                                }
                            }]}
                        }
                    }]
                }
            }]
        }
    })
}

fn album_detail_response_without_library_state() -> Value {
    detail_response(
        json!({
            "musicVisualHeaderRenderer": {
                "title": {"runs": [{"text": "Album Title"}]}
            }
        }),
        vec![song_shelf("Songs", "Song", "song1", Some("OLAK5uy_album"))],
    )
}

fn artist_detail_response_with_subscription_state() -> Value {
    detail_response(
        json!({
            "musicImmersiveHeaderRenderer": {
                "title": {"runs": [{"text": "Chill girl Vibes"}]},
                "buttons": [{
                    "buttonRenderer": {
                        "text": {"runs": [{"text": "Subscribed"}]},
                        "serviceEndpoint": {
                            "unsubscribeEndpoint": {"channelIds": ["UCartist"]}
                        }
                    }
                }]
            }
        }),
        vec![song_shelf("Songs", "Popular Song", "song1", None)],
    )
}

#[test]
fn rejects_invalid_proxy_url() {
    let error = youtube_client(Some("not a url")).unwrap_err();
    assert_eq!(error.code, "invalid-request");
    assert_eq!(error.message, "invalid proxy URL");
}

#[test]
fn retries_youtubei_send_failures_before_succeeding() {
    let mut attempts = 0;
    let mut delays = Vec::new();
    let result: Result<&str> = retry_send_operation(
        || {
            attempts += 1;
            if attempts < 3 {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "temporary timeout",
                ))
            } else {
                Ok("ok")
            }
        },
        |_attempt, delay, _error| delays.push(delay),
    );

    assert_eq!(result.unwrap(), "ok");
    assert_eq!(attempts, 3);
    assert_eq!(
        delays,
        vec![Duration::from_millis(250), Duration::from_millis(750)]
    );
}

#[test]
fn mutation_send_policy_never_retries() {
    let mut attempts = 0;
    let mut retries = 0;
    let error = send_operation(
        SendPolicy::Mutation,
        || -> std::result::Result<(), std::io::Error> {
            attempts += 1;
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "response lost",
            ))
        },
        |_attempt, _delay, _error| retries += 1,
    )
    .unwrap_err();

    assert_eq!(attempts, 1);
    assert_eq!(retries, 0);
    assert_eq!(error.code, "network");
    assert_eq!(error.message, "response lost");
}

#[test]
fn retry_send_error_reports_error_chain_and_attempt_count() {
    let mut attempts = 0;
    let mut retry_attempts = Vec::new();
    let error = retry_send_operation(
        || -> std::result::Result<(), TestOuterError> {
            attempts += 1;
            Err(TestOuterError {
                source: TestSourceError,
            })
        },
        |attempt, _delay, error| {
            retry_attempts.push(attempt);
            assert_eq!(error, "outer error: inner cause");
        },
    )
    .unwrap_err();

    assert_eq!(attempts, 3);
    assert_eq!(retry_attempts, vec![1, 2]);
    assert_eq!(error.code, "network");
    assert_eq!(error.message, "outer error: inner cause after 3 attempts");
}

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
fn account_cache_clear_owns_bootstrap_and_response_paths() {
    let directory = temporary_test_directory();
    fs::create_dir_all(&directory).unwrap();
    let bootstrap_cache = directory.join("bootstrap-cache.json");
    let response_cache = response_cache_dir(&bootstrap_cache);
    fs::write(&bootstrap_cache, "{}").unwrap();
    fs::create_dir_all(&response_cache).unwrap();
    fs::write(response_cache.join("entry.json"), "{}").unwrap();

    clear_account_cache(&bootstrap_cache).unwrap();

    assert!(!bootstrap_cache.exists());
    assert!(!response_cache.exists());
    clear_account_cache(&bootstrap_cache).unwrap();
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
                }},
                "menu": {
                    "menuRenderer": {
                        "items": [{
                            "toggleMenuServiceItemRenderer": {
                                "defaultIcon": {"iconType": "LIBRARY_REMOVE"}
                            }
                        }],
                        "topLevelButtons": [{
                            "likeButtonRenderer": {"likeStatus": "LIKE"}
                        }]
                    }
                }
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
    assert_eq!(
        track.get("like-status").and_then(Value::as_str),
        Some("like")
    );
    assert_eq!(track.get("in-library").and_then(Value::as_bool), Some(true));
}

#[test]
fn parses_segmented_like_status() {
    let renderer = json!({
        "menu": {
            "menuRenderer": {
                "topLevelButtons": [{
                    "segmentedLikeDislikeButtonRenderer": {
                        "likeButton": {
                            "toggleButtonRenderer": {
                                "isToggled": false,
                                "defaultIcon": {"iconType": "LIKE"}
                            }
                        },
                        "dislikeButton": {
                            "toggleButtonRenderer": {
                                "isToggled": true,
                                "defaultIcon": {"iconType": "DISLIKE"}
                            }
                        }
                    }
                }]
            }
        }
    });
    assert_eq!(
        parse_like_status_state(&renderer).status.as_deref(),
        Some("dislike")
    );
}

#[test]
fn parses_indifferent_like_status_as_known() {
    let renderer = json!({
        "likeButtonRenderer": {"likeStatus": "INDIFFERENT"}
    });
    let state = parse_like_status_state(&renderer);
    assert!(state.known);
    assert_eq!(state.status, None);
}

#[test]
fn omits_unknown_like_status_from_track_output() {
    let renderer = json!({
        "title": {"runs": [{"text": "Song"}]},
        "navigationEndpoint": {
            "watchEndpoint": {"videoId": "v1"}
        }
    });
    let item = parse_track(&renderer).unwrap();
    assert!(item.get("like-status").is_none());
}

#[test]
fn keeps_explicit_indifferent_like_status_in_track_output() {
    let renderer = json!({
        "title": {"runs": [{"text": "Song"}]},
        "navigationEndpoint": {
            "watchEndpoint": {"videoId": "v1"}
        },
        "menu": {
            "menuRenderer": {
                "topLevelButtons": [{
                    "likeButtonRenderer": {"likeStatus": "INDIFFERENT"}
                }]
            }
        }
    });
    let item = parse_track(&renderer).unwrap();
    assert!(item.get("like-status").is_some_and(Value::is_null));
}

#[test]
fn track_account_output_omits_unknown_like_status() {
    let unknown = MenuState::default();
    let output = track_account_output("v1", false, &unknown, None, None);
    assert!(output.get("like-status").is_none());

    let known = MenuState {
        like_status_known: true,
        ..Default::default()
    };
    let output = track_account_output("v1", false, &known, None, None);
    assert!(output.get("like-status").is_some_and(Value::is_null));
}

#[test]
fn normalizes_radio_queue_response() {
    let response = json!({
        "contents": {
            "singleColumnMusicWatchNextResultsRenderer": {
                "tabbedRenderer": {
                    "watchNextTabbedResultsRenderer": {
                        "tabs": [{
                            "tabRenderer": {
                                "content": {
                                    "musicQueueRenderer": {
                                        "content": {
                                            "playlistPanelRenderer": {
                                                "contents": [{
                                                    "playlistPanelVideoRenderer": {
                                                        "videoId": "v1",
                                                        "title": {"runs": [{"text": "Seed"}]},
                                                        "longBylineText": {"runs": [{"text": "Artist"}]},
                                                        "lengthText": {"runs": [{"text": "3:05"}]},
                                                        "thumbnail": {"thumbnails": [{"url": "small"}, {"url": "large"}]}
                                                    }
                                                }, {
                                                    "playlistPanelVideoRenderer": {
                                                        "videoId": "v2",
                                                        "title": {"runs": [{"text": "Next"}]}
                                                    }
                                                }],
                                                "continuations": [{
                                                    "nextRadioContinuationData": {
                                                        "continuation": "radio-next"
                                                    }
                                                }]
                                            }
                                        }
                                    }
                                }
                            }
                        }]
                    }
                }
            }
        }
    });
    let normalized = normalize_radio_response("v1", 10, &response);
    assert_eq!(
        normalized
            .pointer("/sources/0/kind")
            .and_then(Value::as_str),
        Some("youtube-music-radio")
    );
    assert_eq!(
        normalized
            .pointer("/sources/0/items/0/id")
            .and_then(Value::as_str),
        Some("v1")
    );
    assert_eq!(
        normalized
            .pointer("/sources/0/items/0/duration")
            .and_then(Value::as_u64),
        Some(185)
    );
    assert_eq!(
        normalized
            .pointer("/sources/0/continuation")
            .and_then(Value::as_str),
        Some("radio-next")
    );
}

#[test]
fn normalizes_add_to_playlist_options() {
    let response = json!({
        "addToPlaylistRenderer": {
            "title": {"runs": [{"text": "Add to playlist"}]},
            "contents": [{
                "playlistAddToOptionRenderer": {
                    "playlistId": "PL1",
                    "title": {"runs": [{"text": "Road songs"}]},
                    "subtitle": {"runs": [{"text": "Private"}]},
                    "selected": false
                }
            }, {
                "playlistAddToOptionRenderer": {
                    "playlistId": "PL1",
                    "title": {"runs": [{"text": "Duplicate"}]}
                }
            }],
            "createPlaylistEndpoint": {}
        }
    });
    let normalized = normalize_add_to_playlist_options(&response);
    let options = normalized
        .get("options")
        .and_then(Value::as_array)
        .expect("options");
    assert_eq!(options.len(), 1);
    assert_eq!(
        options[0].get("playlist-id").and_then(Value::as_str),
        Some("PL1")
    );
    assert_eq!(
        options[0].get("title").and_then(Value::as_str),
        Some("Road songs")
    );
    assert_eq!(
        normalized
            .get("can-create-playlist")
            .and_then(Value::as_bool),
        Some(true)
    );
}

#[test]
fn parses_song_library_state_tokens() {
    let response = json!({
        "contents": {
            "singleColumnMusicWatchNextResultsRenderer": {
                "tabbedRenderer": {
                    "watchNextTabbedResultsRenderer": {
                        "tabs": [{
                            "tabRenderer": {
                                "content": {
                                    "musicQueueRenderer": {
                                        "content": {
                                            "playlistPanelRenderer": {
                                                "contents": [{
                                                    "playlistPanelVideoRenderer": {
                                                        "videoId": "v1",
                                                        "title": {"runs": [{"text": "Song"}]},
                                                        "menu": {
                                                            "menuRenderer": {
                                                                "items": [{
                                                                    "toggleMenuServiceItemRenderer": {
                                                                        "defaultIcon": {"iconType": "LIBRARY_ADD"},
                                                                        "defaultServiceEndpoint": {
                                                                            "feedbackEndpoint": {"feedbackToken": "add-token"}
                                                                        },
                                                                        "toggledServiceEndpoint": {
                                                                            "feedbackEndpoint": {"feedbackToken": "remove-token"}
                                                                        }
                                                                    }
                                                                }],
                                                                "topLevelButtons": [{
                                                                    "likeButtonRenderer": {"likeStatus": "LIKE"}
                                                                }]
                                                            }
                                                        }
                                                    }
                                                }]
                                            }
                                        }
                                    }
                                }
                            }
                        }]
                    }
                }
            }
        }
    });
    let state = song_library_state(&response, "v1").unwrap();
    assert!(!state.in_library);
    assert_eq!(state.add_token.as_deref(), Some("add-token"));
    assert_eq!(state.remove_token.as_deref(), Some("remove-token"));
    assert_eq!(state.like_status.as_deref(), Some("like"));
}

#[test]
fn subscription_toggle_state_uses_default_subscribe_endpoint() {
    let renderer = json!({
        "toggleMenuServiceItemRenderer": {
            "text": {"runs": [{"text": "Subscribe"}]},
            "defaultServiceEndpoint": {
                "subscribeEndpoint": {"channelIds": ["UC1"]}
            },
            "toggledServiceEndpoint": {
                "unsubscribeEndpoint": {"channelIds": ["UC1"]},
                "label": "Unsubscribe"
            }
        }
    });
    let mut state = MenuState::default();
    collect_menu_state(&renderer, &mut state);

    assert_eq!(state.subscribed, Some(false));
    assert_eq!(
        state
            .subscribe_endpoint
            .as_ref()
            .and_then(|endpoint| endpoint.channel_ids.first())
            .map(String::as_str),
        Some("UC1")
    );
    assert!(state.unsubscribe_endpoint.is_some());
}

#[test]
fn subscription_toggle_state_uses_default_unsubscribe_endpoint() {
    let renderer = json!({
        "toggleMenuServiceItemRenderer": {
            "text": {"runs": [{"text": "Unsubscribe"}]},
            "defaultServiceEndpoint": {
                "unsubscribeEndpoint": {"channelIds": ["UC1"]}
            },
            "toggledServiceEndpoint": {
                "subscribeEndpoint": {"channelIds": ["UC1"]},
                "label": "Subscribe"
            }
        }
    });
    let mut state = MenuState::default();
    collect_menu_state(&renderer, &mut state);

    assert_eq!(state.subscribed, Some(true));
    assert_eq!(
        state
            .unsubscribe_endpoint
            .as_ref()
            .and_then(|endpoint| endpoint.channel_ids.first())
            .map(String::as_str),
        Some("UC1")
    );
    assert!(state.subscribe_endpoint.is_some());
}

#[test]
fn subscription_button_state_uses_explicit_subscribed_flag() {
    let renderer = json!({
        "subscribeButtonRenderer": {
            "channelId": "UC1",
            "subscribed": false,
            "unsubscribedButtonText": {"runs": [{"text": "Subscribe"}]},
            "subscribedButtonText": {"runs": [{"text": "Subscribed"}]},
            "serviceEndpoints": [
                {
                    "subscribeEndpoint": {
                        "channelIds": ["UC1"],
                        "params": "subscribe-params"
                    }
                },
                {
                    "signalServiceEndpoint": {
                        "actions": [{
                            "openPopupAction": {
                                "popup": {
                                    "confirmDialogRenderer": {
                                        "confirmButton": {
                                            "buttonRenderer": {
                                                "serviceEndpoint": {
                                                    "unsubscribeEndpoint": {
                                                        "channelIds": ["UC1"]
                                                    }
                                                },
                                                "text": {"runs": [{"text": "Unsubscribe"}]}
                                            }
                                        }
                                    }
                                }
                            }
                        }]
                    }
                }
            ]
        }
    });
    let mut state = MenuState::default();
    collect_menu_state(&renderer, &mut state);

    assert_eq!(state.subscribed, Some(false));
    assert_eq!(
        state
            .subscribe_endpoint
            .as_ref()
            .and_then(|endpoint| endpoint.params.as_deref()),
        Some("subscribe-params")
    );
    assert!(state.unsubscribe_endpoint.is_some());
}

#[test]
fn song_library_state_requires_matching_video_id() {
    let response = json!({
        "contents": [{
            "playlistPanelVideoRenderer": {
                "videoId": "other-video",
                "title": {"runs": [{"text": "Other"}]},
                "menu": {
                    "menuRenderer": {
                        "items": [{
                            "toggleMenuServiceItemRenderer": {
                                "defaultIcon": {"iconType": "LIBRARY_ADD"},
                                "defaultServiceEndpoint": {
                                    "feedbackEndpoint": {"feedbackToken": "wrong-add-token"}
                                }
                            }
                        }]
                    }
                }
            }
        }]
    });
    let error = song_library_state(&response, "target-id").unwrap_err();
    assert!(error.message.contains("target-id"));
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
                                                "subtitle": {"runs": [{"text": "Artist A"}]},
                                                "menu": {
                                                    "menuRenderer": {
                                                        "topLevelButtons": [{
                                                            "likeButtonRenderer": {"likeStatus": "LIKE"}
                                                        }]
                                                    }
                                                }
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
        sources[0]
            .pointer("/items/0/like-status")
            .and_then(Value::as_str),
        Some("like")
    );
    assert_eq!(
        sources[1].pointer("/items/0/type").and_then(Value::as_str),
        Some("playlist")
    );
}

#[test]
fn normalizes_home_rich_shelf_music_videos_as_source() {
    let response = json!({
        "contents": {
            "singleColumnBrowseResultsRenderer": {
                "tabs": [{
                    "tabRenderer": {
                        "content": {
                            "sectionListRenderer": {
                                "contents": [{
                                    "richSectionRenderer": {
                                        "content": {
                                            "richShelfRenderer": {
                                                "title": {
                                                    "runs": [{"text": "Music videos for you"}]
                                                },
                                                "contents": [{
                                                    "richItemRenderer": {
                                                        "content": {
                                                            "compactVideoRenderer": {
                                                                "title": {
                                                                    "simpleText": "Video Song"
                                                                },
                                                                "navigationEndpoint": {
                                                                    "watchEndpoint": {
                                                                        "videoId": "abc123DEF45"
                                                                    }
                                                                },
                                                                "longBylineText": {
                                                                    "runs": [{
                                                                        "text": "Video Artist",
                                                                        "navigationEndpoint": {
                                                                            "browseEndpoint": {
                                                                                "browseId": "UCVIDEO"
                                                                            }
                                                                        }
                                                                    }]
                                                                },
                                                                "thumbnail": {
                                                                    "thumbnails": [
                                                                        {"url": "video-small"},
                                                                        {"url": "video-large"}
                                                                    ]
                                                                }
                                                            }
                                                        }
                                                    }
                                                }]
                                            }
                                        }
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
        Some("Music videos for you")
    );
    assert_eq!(
        sources[0].pointer("/items/0/type").and_then(Value::as_str),
        Some("track")
    );
    assert_eq!(
        sources[0].pointer("/items/0/id").and_then(Value::as_str),
        Some("abc123DEF45")
    );
    assert_eq!(
        sources[0].pointer("/items/0/title").and_then(Value::as_str),
        Some("Video Song")
    );
    assert_eq!(
        sources[0]
            .pointer("/items/0/artist")
            .and_then(Value::as_str),
        Some("Video Artist")
    );
    assert_eq!(
        sources[0]
            .pointer("/items/0/thumbnail-url")
            .and_then(Value::as_str),
        Some("video-large")
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
        ]
    );
}

#[test]
fn normalizes_library_songs_without_shuffle_all_action() {
    let response = json!({
        "contents": [{
            "musicResponsiveListItemRenderer": {
                "title": {"runs": [{"text": "Shuffle all"}]},
                "navigationEndpoint": {
                    "watchPlaylistEndpoint": {"playlistId": "MLCT"}
                }
            }
        }, {
            "musicResponsiveListItemRenderer": {
                "flexColumns": [
                    {"musicResponsiveListItemFlexColumnRenderer": {
                        "text": {"runs": [{
                            "text": "Song",
                            "navigationEndpoint": {"watchEndpoint": {"videoId": "v1"}}
                        }]}
                    }},
                    {"musicResponsiveListItemFlexColumnRenderer": {
                        "text": {"runs": [{"text": "Artist"}]}
                    }}
                ],
                "fixedColumns": [{"musicResponsiveListItemFixedColumnRenderer": {
                    "text": {"runs": [{"text": "3:30"}]}
                }}]
            }
        }]
    });
    let normalized = normalize_response(&BrowseTarget::LibrarySongs, 10, &response);
    let items = normalized
        .pointer("/sources/0/items")
        .and_then(Value::as_array)
        .expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].get("title").and_then(Value::as_str), Some("Song"));
    assert_eq!(items[0].get("type").and_then(Value::as_str), Some("track"));
}

#[test]
fn normalizes_library_playlists_without_new_playlist_action() {
    let response = json!({
        "contents": [{
            "musicResponsiveListItemRenderer": {
                "title": {"runs": [{"text": "New playlist"}]},
                "thumbnail": {
                    "musicThumbnailRenderer": {
                        "thumbnail": {
                            "thumbnails": [{
                                "url": "https://www.gstatic.com/youtube/media/ytm/images/pbg/create-playlist-@210.png"
                            }]
                        }
                    }
                }
            }
        }, {
            "musicTwoRowItemRenderer": {
                "title": {"runs": [{"text": "Fav"}]},
                "navigationEndpoint": {
                    "browseEndpoint": {"browseId": "VLPL1"}
                },
                "thumbnailRenderer": {
                    "musicThumbnailRenderer": {
                        "thumbnail": {"thumbnails": [{"url": "cover"}]}
                    }
                }
            }
        }]
    });
    let normalized = normalize_response(&BrowseTarget::LibraryPlaylists, 10, &response);
    let items = normalized
        .pointer("/sources/0/items")
        .and_then(Value::as_array)
        .expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].get("title").and_then(Value::as_str), Some("Fav"));
    assert_eq!(
        items[0].get("type").and_then(Value::as_str),
        Some("playlist")
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
                        }, {
                            "musicTwoRowItemRenderer": {
                                "title": {"runs": [{"text": "Explore Song"}]},
                                "navigationEndpoint": {
                                    "watchEndpoint": {"videoId": "v1"}
                                },
                                "menu": {
                                    "menuRenderer": {
                                        "topLevelButtons": [{
                                            "likeButtonRenderer": {"likeStatus": "LIKE"}
                                        }]
                                    }
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
    assert_eq!(
        source.pointer("/items/1/type").and_then(Value::as_str),
        Some("track")
    );
    assert_eq!(
        source
            .pointer("/items/1/like-status")
            .and_then(Value::as_str),
        Some("like")
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
                ]},
                "menu": {"menuRenderer": {"items": [{
                    "menuServiceItemRenderer": {
                        "title": {"runs": [{"text": "Remove playlist from library"}]},
                        "icon": {"iconType": "BOOKMARK"},
                        "serviceEndpoint": {
                            "feedbackEndpoint": {"feedbackToken": "remove-playlist"}
                        }
                    }
                }]}}
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
    assert_eq!(
        normalized
            .pointer("/sources/0/items/0/in-library")
            .and_then(Value::as_bool),
        Some(true)
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
                        "buttons": [{
                            "buttonRenderer": {
                                "text": {"runs": [{"text": "Subscribed"}]},
                                "serviceEndpoint": {
                                    "unsubscribeEndpoint": {"channelIds": ["UCCHILL"]}
                                }
                            }
                        }],
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
        sources[0]
            .pointer("/items/0/subscribed")
            .and_then(Value::as_bool),
        Some(true)
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
fn normalizes_search_item_sections_after_top_result() {
    let response = json!({
        "contents": {
            "tabbedSearchResultsRenderer": {
                "tabs": [{
                    "tabRenderer": {
                        "title": "YT Music",
                        "selected": true,
                        "content": {
                            "sectionListRenderer": {
                                "contents": [{
                                    "musicCardShelfRenderer": {
                                        "title": {"runs": [{
                                            "text": "'00s R&B Chill",
                                            "navigationEndpoint": {
                                                "browseEndpoint": {
                                                    "browseId": "VLRDCHILL"
                                                }
                                            }
                                        }]},
                                        "subtitle": {"runs": [
                                            {"text": "Playlist"},
                                            {"text": " • "},
                                            {"text": "YouTube Music"}
                                        ]},
                                        "thumbnail": {"musicThumbnailRenderer": {
                                            "thumbnail": {"thumbnails": [{"url": "playlist-thumb"}]}
                                        }}
                                    }
                                }, {
                                    "itemSectionRenderer": {
                                        "contents": [{
                                            "musicResponsiveListItemRenderer": {
                                                "flexColumns": [{
                                                    "musicResponsiveListItemFlexColumnRenderer": {
                                                        "text": {"runs": [{"text": "Chill Girl"}]}
                                                    }
                                                }, {
                                                    "musicResponsiveListItemFlexColumnRenderer": {
                                                        "text": {"runs": [
                                                            {"text": "Song"},
                                                            {"text": " • "},
                                                            {"text": "CeeProlific"}
                                                        ]}
                                                    }
                                                }],
                                                "navigationEndpoint": {
                                                    "watchEndpoint": {"videoId": "song1"}
                                                }
                                            }
                                        }]
                                    }
                                }, {
                                    "itemSectionRenderer": {
                                        "contents": [{
                                            "musicResponsiveListItemRenderer": {
                                                "flexColumns": [{
                                                    "musicResponsiveListItemFlexColumnRenderer": {
                                                        "text": {"runs": [{"text": "Different Dinner Table"}]}
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
                                                    "watchEndpoint": {"videoId": "song2"}
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
                        "title": "Library",
                        "content": {
                            "sectionListRenderer": {
                                "contents": [{
                                    "itemSectionRenderer": {
                                        "contents": [{
                                            "musicResponsiveListItemRenderer": {
                                                "flexColumns": [{
                                                    "musicResponsiveListItemFlexColumnRenderer": {
                                                        "text": {"runs": [{"text": "Library-only"}]}
                                                    }
                                                }],
                                                "navigationEndpoint": {
                                                    "watchEndpoint": {"videoId": "library"}
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
    let normalized = normalize_search_response("chill girl", 10, &response);
    let sources = normalized
        .get("sources")
        .and_then(Value::as_array)
        .expect("sources");
    assert_eq!(sources.len(), 2);
    assert_eq!(
        sources[0].get("title").and_then(Value::as_str),
        Some("Top result")
    );
    assert_eq!(
        sources[0].pointer("/items/0/title").and_then(Value::as_str),
        Some("'00s R&B Chill")
    );
    assert_eq!(
        sources[1].get("title").and_then(Value::as_str),
        Some("Results")
    );
    assert_eq!(
        sources[1].pointer("/items/0/id").and_then(Value::as_str),
        Some("song1")
    );
    assert_eq!(
        sources[1].pointer("/items/1/id").and_then(Value::as_str),
        Some("song2")
    );
    assert!(sources[1]
        .get("items")
        .and_then(Value::as_array)
        .expect("items")
        .iter()
        .all(|item| item.get("id").and_then(Value::as_str) != Some("library")));
}

#[test]
fn normalizes_browse_id_response_as_detail_source() {
    let response = json!({
        "header": {
            "musicDetailHeaderRenderer": {
                "title": {"runs": [{"text": "Playlist Title"}]},
                "menu": {"menuRenderer": {"items": [{
                    "menuServiceItemRenderer": {
                        "title": {"runs": [{"text": "Remove playlist from library"}]},
                        "icon": {"iconType": "BOOKMARK"},
                        "serviceEndpoint": {
                            "feedbackEndpoint": {"feedbackToken": "remove-playlist"}
                        }
                    }
                }]}}
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
        source.get("in-library").and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        source.get("playlist-id").and_then(Value::as_str),
        Some("PL1")
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
fn album_detail_source_uses_album_playlist_id() {
    let response = json!({
        "header": {
            "musicVisualHeaderRenderer": {
                "title": {"runs": [{"text": "Smoke Rings"}]}
            }
        },
        "contents": {
            "twoColumnBrowseResultsRenderer": {
                "secondaryContents": {
                    "sectionListRenderer": {
                        "contents": [{
                            "musicShelfRenderer": {
                                "contents": [{
                                    "musicResponsiveListItemRenderer": {
                                        "flexColumns": [{
                                            "musicResponsiveListItemFlexColumnRenderer": {
                                                "text": {"runs": [{
                                                    "text": "Whiskey On My Mind",
                                                    "navigationEndpoint": {
                                                        "watchEndpoint": {
                                                            "videoId": "z9fvoc5j828",
                                                            "playlistId": "OLAK5uy_album"
                                                        }
                                                    }
                                                }]}
                                            }
                                        }]
                                    }
                                }]
                            }
                        }]
                    }
                }
            }
        }
    });
    assert_eq!(
        item_library_playlist_id("MPRE1", &response).as_deref(),
        Some("OLAK5uy_album")
    );
    let normalized = normalize_browse_id_response("MPRE1", 10, &response);
    let source = normalized.pointer("/sources/0").unwrap();
    assert_eq!(
        source.get("playlist-id").and_then(Value::as_str),
        Some("OLAK5uy_album")
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
                }},
                "buttons": [{
                    "buttonRenderer": {
                        "text": {"runs": [{"text": "Subscribed"}]},
                        "serviceEndpoint": {
                            "unsubscribeEndpoint": {"channelIds": ["UCartist"]}
                        }
                    }
                }]
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
        sources[0].get("subscribed").and_then(Value::as_bool),
        Some(true)
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
fn detail_mutation_output_overrides_subscription_source_state() {
    let response = artist_detail_response_with_subscription_state();
    let output = detail_mutation_output(
        "UCartist",
        &response,
        "unsubscribe",
        true,
        None,
        Some(false),
    );
    let sources = output
        .get("sources")
        .and_then(Value::as_array)
        .expect("sources");
    assert_eq!(
        output.get("subscribed").and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(
        sources[0].get("subscribed").and_then(Value::as_bool),
        Some(false)
    );
    assert_eq!(sources[1].get("subscribed").and_then(Value::as_bool), None);
}

#[test]
fn detail_mutation_output_overrides_library_source_state() {
    let response = album_detail_response_without_library_state();
    let output = detail_mutation_output("MPRE1", &response, "save", true, Some(true), None);
    let sources = output
        .get("sources")
        .and_then(Value::as_array)
        .expect("sources");
    assert_eq!(
        output.get("in-library").and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(
        sources[0].get("in-library").and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(sources[1].get("in-library").and_then(Value::as_bool), None);
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
