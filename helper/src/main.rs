mod auth;
mod ytmusic;

use auth::import_headers;
use auth::{import_browser, import_dia, AuthConfig, DEFAULT_DIA_APP_PATH};
use serde::Serialize;
use serde_json::{json, Value};
use std::env;
use std::path::PathBuf;
use std::process;
use ytmusic::{browse, BrowseTarget};

const SCHEMA_VERSION: u32 = 1;
const DEFAULT_DIA_CDP_PORT: u16 = 29317;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    AuthCheck,
    AuthImportBrowser {
        browser: String,
        output: PathBuf,
        yt_dlp: String,
    },
    AuthImportHeaders {
        input: PathBuf,
        output: PathBuf,
    },
    AuthImportDia {
        output: PathBuf,
        port: u16,
        app: PathBuf,
        restart: bool,
    },
    Browse(BrowseTarget),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Options {
    command: Command,
    auth_file: Option<PathBuf>,
    limit: usize,
    mock_data: bool,
}

#[derive(Serialize)]
struct Envelope<T> {
    ok: bool,
    schema: u32,
    data: T,
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
            process::exit(1);
        }
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
    let data = match &options.command {
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
        Command::AuthImportBrowser {
            browser,
            output,
            yt_dlp,
        } => {
            let config = import_browser(browser, output, yt_dlp)?;
            json!({
                "auth": {
                    "configured": true,
                    "source": config.source,
                    "path": output
                }
            })
        }
        Command::AuthImportHeaders { input, output } => {
            let config = import_headers(input, output)?;
            json!({
                "auth": {
                    "configured": true,
                    "source": config.source,
                    "path": output
                }
            })
        }
        Command::AuthImportDia {
            output,
            port,
            app,
            restart,
        } => {
            let config = import_dia(output, *port, app, *restart)?;
            json!({
                "auth": {
                    "configured": true,
                    "source": config.source,
                    "path": output
                }
            })
        }
        Command::Browse(target) if options.mock_data => mock_browse(target, options.limit),
        Command::Browse(target) => {
            let auth = AuthConfig::load(required_auth_path(&options)?)?;
            browse(target, options.limit, &auth)?
        }
    };
    serde_json::to_string(&Envelope {
        ok: true,
        schema: SCHEMA_VERSION,
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
        "auth" => parse_auth_command(&mut args)?,
        "browse" => parse_browse_command(&mut args)?,
        "help" | "--help" | "-h" => return Err(usage()),
        other => return Err(format!("unknown command `{other}`")),
    };

    let mut auth_file = None;
    let mut limit = 100;
    let mut mock_data = false;
    let mut browser = None;
    let mut input = None;
    let mut output = None;
    let mut port = None;
    let mut app = None;
    let mut restart = false;
    let mut yt_dlp = "yt-dlp".to_string();
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
            "--mock" => mock_data = true,
            "--browser" => browser = Some(option_value(&args, &mut index)?.to_string()),
            "--input" => input = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--output" => output = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--port" => {
                let value = option_value(&args, &mut index)?;
                port = Some(
                    value
                        .parse::<u16>()
                        .map_err(|_| format!("invalid port `{value}`"))?,
                );
            }
            "--app" => app = Some(PathBuf::from(option_value(&args, &mut index)?)),
            "--restart" => restart = true,
            "--yt-dlp" => yt_dlp = option_value(&args, &mut index)?.to_string(),
            other => return Err(format!("unknown option `{other}`")),
        }
        index += 1;
    }

    let command = match command {
        Command::AuthImportBrowser { .. } => {
            if input.is_some() {
                return Err("header import options require `auth import-headers`".to_string());
            }
            if port.is_some() || app.is_some() || restart {
                return Err("Dia import options require `auth import-dia`".to_string());
            }
            Command::AuthImportBrowser {
                browser: browser.ok_or_else(|| "missing --browser BROWSER".to_string())?,
                output: output.ok_or_else(|| "missing --output FILE".to_string())?,
                yt_dlp,
            }
        }
        Command::AuthImportHeaders { .. } => {
            if browser.is_some() || port.is_some() || app.is_some() || restart || yt_dlp != "yt-dlp"
            {
                return Err("browser options require `auth import-browser`".to_string());
            }
            Command::AuthImportHeaders {
                input: input.ok_or_else(|| "missing --input FILE".to_string())?,
                output: output.ok_or_else(|| "missing --output FILE".to_string())?,
            }
        }
        Command::AuthImportDia { .. } => {
            if browser.is_some() || input.is_some() || yt_dlp != "yt-dlp" {
                return Err("non-Dia import options require their matching auth action".to_string());
            }
            Command::AuthImportDia {
                output: output.ok_or_else(|| "missing --output FILE".to_string())?,
                port: port.unwrap_or(DEFAULT_DIA_CDP_PORT),
                app: app.unwrap_or_else(|| PathBuf::from(DEFAULT_DIA_APP_PATH)),
                restart,
            }
        }
        other => {
            if browser.is_some()
                || input.is_some()
                || output.is_some()
                || port.is_some()
                || app.is_some()
                || restart
                || yt_dlp != "yt-dlp"
            {
                return Err("auth import options require an auth import action".to_string());
            }
            other
        }
    };

    Ok(Options {
        command,
        auth_file,
        limit,
        mock_data,
    })
}

fn parse_auth_command(args: &mut Vec<String>) -> Result<Command, String> {
    let Some(action) = args.first().cloned() else {
        return Err("expected an auth action".to_string());
    };
    args.remove(0);
    match action.as_str() {
        "check" => Ok(Command::AuthCheck),
        "import-browser" => Ok(Command::AuthImportBrowser {
            browser: String::new(),
            output: PathBuf::new(),
            yt_dlp: String::new(),
        }),
        "import-headers" => Ok(Command::AuthImportHeaders {
            input: PathBuf::new(),
            output: PathBuf::new(),
        }),
        "import-dia" => Ok(Command::AuthImportDia {
            output: PathBuf::new(),
            port: DEFAULT_DIA_CDP_PORT,
            app: PathBuf::from(DEFAULT_DIA_APP_PATH),
            restart: false,
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
        "library" => BrowseTarget::Library,
        "liked" => BrowseTarget::Liked,
        other => return Err(format!("unknown browse target `{other}`")),
    }))
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
        "  ytm-radio-helper auth check --auth FILE",
        "  ytm-radio-helper auth import-browser --browser BROWSER --output FILE [--yt-dlp PROGRAM]",
        "  ytm-radio-helper auth import-headers --input FILE --output FILE",
        "  ytm-radio-helper auth import-dia --output FILE [--port N] [--app PATH] [--restart]",
        "  ytm-radio-helper browse home|library|liked --auth FILE [--limit N]",
        "  ytm-radio-helper browse home|library|liked --mock [--limit N]",
    ]
    .join("\n")
}

fn mock_browse(target: &BrowseTarget, limit: usize) -> Value {
    if matches!(target, BrowseTarget::Home) {
        return mock_home_browse(limit);
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
        BrowseTarget::Library => (
            "ytm:library:songs",
            "youtube-music-library",
            "Library Songs",
            "ytm://library/songs",
            "mock-library-track",
            "Mock Library Track",
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
            "url": "https://music.youtube.com/playlist?list=mock-playlist"
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

fn mock_home_browse(limit: usize) -> Value {
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
            "subtitle": "Mock Artist",
            "thumbnail-url": null
        }));
    }
    json!({
        "sources": [{
            "id": "ytm:home:mock:listen-again",
            "kind": "youtube-music-home-section",
            "title": "Listen again",
            "url": "ytm://home/mock",
            "items": listen_again,
            "continuation": null
        }, {
            "id": "ytm:home:mock:mixed-for-you",
            "kind": "youtube-music-home-section",
            "title": "Mixed for you",
            "url": "ytm://home/mock",
            "items": [{
                "type": "playlist",
                "id": "mock-mix",
                "title": "Mock Mix",
                "url": "https://music.youtube.com/playlist?list=mock-mix",
                "subtitle": "Playlist",
                "thumbnail-url": null
            }],
            "continuation": null
        }]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
            }
        );
    }

    #[test]
    fn parses_browser_import_command() {
        let options = parse_args([
            "auth",
            "import-browser",
            "--browser",
            "chrome:Default",
            "--output",
            "/tmp/auth.json",
        ])
        .unwrap();
        assert_eq!(
            options.command,
            Command::AuthImportBrowser {
                browser: "chrome:Default".to_string(),
                output: PathBuf::from("/tmp/auth.json"),
                yt_dlp: "yt-dlp".to_string(),
            }
        );
    }

    #[test]
    fn parses_header_import_command() {
        let options = parse_args([
            "auth",
            "import-headers",
            "--input",
            "/tmp/headers.txt",
            "--output",
            "/tmp/auth.json",
        ])
        .unwrap();
        assert_eq!(
            options.command,
            Command::AuthImportHeaders {
                input: PathBuf::from("/tmp/headers.txt"),
                output: PathBuf::from("/tmp/auth.json"),
            }
        );
    }

    #[test]
    fn parses_dia_import_command() {
        let options = parse_args([
            "auth",
            "import-dia",
            "--output",
            "/tmp/auth.json",
            "--port",
            "29999",
            "--app",
            "/Applications/Dia.app/Contents/MacOS/Dia",
        ])
        .unwrap();
        assert_eq!(
            options.command,
            Command::AuthImportDia {
                output: PathBuf::from("/tmp/auth.json"),
                port: 29999,
                app: PathBuf::from("/Applications/Dia.app/Contents/MacOS/Dia"),
                restart: false,
            }
        );
    }

    #[test]
    fn parses_dia_import_restart_flag() {
        let options = parse_args([
            "auth",
            "import-dia",
            "--output",
            "/tmp/auth.json",
            "--restart",
        ])
        .unwrap();
        match options.command {
            Command::AuthImportDia { restart, .. } => assert!(restart),
            other => panic!("unexpected command: {other:?}"),
        }
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
    fn mock_browse_outputs_track_items() {
        let output = run(["browse", "library", "--mock", "--limit", "1"]).unwrap();
        assert!(output.contains(r#""schema":1"#));
        assert!(output.contains(r#""id":"ytm:library:songs""#));
        assert!(output.contains(r#""type":"track""#));
        assert!(!output.contains(r#""type":"playlist""#));
    }
}
