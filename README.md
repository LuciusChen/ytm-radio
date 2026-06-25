# ytm-radio

An experimental Emacs audio player for YouTube and YouTube Music.

`yt-dlp` discovers URL metadata for URL imports, and `mpv` plays audio with
video disabled. Emacs owns the catalog, playback state, selection commands,
and UI.

YouTube Music account access is a separate Rust CLI. It is not an Emacs
dynamic module and does not run as a resident service. Emacs starts one
process for a request, reads a versioned JSON response, and the process exits.

## Status

Implemented:

- add YouTube and YouTube Music URLs through `yt-dlp`;
- normalize playlists, channels, and tracks into a local catalog;
- play through `mpv --no-video`;
- pause, next, previous, stop, and seek through mpv IPC;
- show YouTube Music browse pages in a regular buffer;
- show the current cover, playback progress, and controls in a child-frame
  now-playing view;
- expose current-track actions through a transient menu;
- invoke an external Rust account helper;
- import YouTube Music auth through a browser login window and the
  browser's DevTools protocol;
- make authenticated YouTube Music home, library, liked, and search requests;
- normalize live music renderers into playable tracks;
- preserve non-track YouTube Music items such as albums, artists, playlists,
  and recommendation cards when they are present in browse responses;
- render Home and Library as Emacs-native section dashboards;
- import deterministic mock account data;
- reject unsupported helper JSON schema versions.

Not implemented yet:

- detail pages for every album, artist, playlist, and radio renderer;
- encrypted credential storage;
- local account-data caching;
- full renderer coverage for every YouTube Music web card type.

The live API is an unofficial YouTube Music web protocol and can change without
notice. The helper dynamically reads current client configuration from the
YouTube Music page instead of hardcoding the API key.

## Requirements

- Emacs 29.1 or newer
- `transient`
- `yt-dlp`
- `mpv`
- a Rust toolchain for building the optional account helper

No Python runtime or Python package is used.

## Setup

Build the helper:

```sh
cargo build --manifest-path helper/Cargo.toml
```

Load the Emacs package:

```elisp
(add-to-list 'load-path "/Users/luciuschen/repos/ytm-radio")
(require 'ytm-radio)
```

Opening `M-x ytm-radio` does not prompt for a URL when the catalog is empty.
When account access is needed, ytm-radio opens the login flow automatically.
Use `H`, `E`, `L`, `/`, or `a` to browse account pages, search, or add a URL.

The main `*ytm-radio*` buffer is the YouTube Music browser. It renders Home,
Explore, Library, Search, and URL-backed pages as vertical Emacs sections with
compact track/card rows. Home, Explore, and Library sections preserve YouTube
Music modules such as listen-again, mixed-for-you, albums, playlists, artists,
and liked music when the web response includes them.
Home, Explore, and Library use cached sections first and only load asynchronously
when a view has no cached data or when explicitly refreshed. Home continuation
pages load lazily when the visible Home buffer reaches the rendered end.

The child frame is a compact now-playing surface. It fits itself to the current
cover image, shows title, artist, time, and progress, and exposes the core
playback controls without turning the child frame into the main browser.

The default helper path points to:

```text
helper/target/debug/ytm-radio-helper
```

Set `ytm-radio-helper-command` explicitly when installing the binary
elsewhere:

```elisp
(setq ytm-radio-helper-command
      "/absolute/path/to/ytm-radio-helper")
```

Run `M-x ytm-radio-doctor` when playback, login import, or account browsing
does not start. It reports whether the helper, `mpv`, `yt-dlp`, the runtime
directory, and the auth file are visible from Emacs.

## Commands

- `M-x ytm-radio` opens the YouTube Music browser buffer.
- `M-x ytm-radio-doctor` shows a setup diagnostic report.
- `M-x ytm-radio-home` switches to Home.
- `M-x ytm-radio-explore` switches to Explore.
- `M-x ytm-radio-library` switches to Library.
- `M-x ytm-radio-add-url` adds a YouTube or YouTube Music URL asynchronously.
- `M-x ytm-radio-import-ytmusic-library` imports library sources.
- `M-x ytm-radio-import-ytmusic-home` imports home recommendations.
- `M-x ytm-radio-more` opens hidden items in the current section.
- `M-x ytm-radio-load-more-home` imports the next Home continuation page.
- `M-x ytm-radio-import-ytmusic-explore` imports explore sections.
- `M-x ytm-radio-import-ytmusic-liked` imports liked songs.
- `M-x ytm-radio-refresh` refreshes the current browser view.
- `M-x ytm-radio-search` searches YouTube Music.
- `M-x ytm-radio-now-playing` shows the cover child frame.
- `M-x ytm-radio-queue` shows the current runtime playback queue.
- `M-x ytm-radio-play-track` selects a known track.
- `M-x ytm-radio-play-source` selects a known source.
- `M-x ytm-radio-current-actions` opens actions for the current track.
- `M-x ytm-radio-like-current-track` likes or unlikes the current track.
- `M-x ytm-radio-dislike-current-track` dislikes or undislikes the current
  track.
- `M-x ytm-radio-toggle-current-track-library` saves or removes the current
  track from the YouTube Music library.
- `M-x ytm-radio-start-current-track-mix` starts a YouTube Music mix queue from
  the current track.
- `M-x ytm-radio-add-current-track-to-playlist` adds the current track to a
  selected YouTube Music playlist.
- `M-x ytm-radio-play-current-track-next` inserts the current track after the
  current runtime queue position.
- `M-x ytm-radio-add-current-track-to-queue` appends the current track to the
  runtime queue.
- `M-x ytm-radio-toggle-pause` toggles mpv pause.
- `M-x ytm-radio-cycle-repeat` cycles repeat off, all, and one.
- `M-x ytm-radio-toggle-shuffle` toggles shuffle playback.
- `M-x ytm-radio-stop` stops playback.
- `M-x ytm-radio-next` plays the next track.
- `M-x ytm-radio-previous` plays the previous track.
- `M-x ytm-radio-share` copies the current track URL.
- `M-x ytm-radio-seek-forward` seeks forward.
- `M-x ytm-radio-seek-backward` seeks backward.
- `M-x ytm-radio-hide-browser` hides the browser buffer.
- `M-x ytm-radio-hide-now-playing` hides the now-playing child frame.
- `M-x ytm-radio-hide` hides ytm-radio UI.

Inside the browser buffer:

| Key | Action |
| --- | --- |
| `a` | Add URL |
| `c` | Show cover child frame |
| `H` | Switch to Home |
| `E` | Switch to Explore |
| `L` | Switch to Library |
| `i` | Import liked songs |
| `/` | Search YouTube Music |
| `RET` | Play a track or open the item/source at point |
| `j`, `k`, `Down`, `Up` | Move between item rows |
| `m` | Open more items for the current section |
| `g` | Refresh the current browser view |
| `TAB`, `S-TAB` | Move between sections |
| `b` | Return to the previous browser view |
| `s` | Play source at point, or select a source |
| `SPC` | Toggle pause |
| `n` | Next track |
| `p` | Previous track |
| `A` | Open current-track actions |
| `l` | Like or unlike the current track |
| `d` | Dislike or undislike the current track |
| `R` | Start mix from the current track |
| `P` | Add current track to a playlist |
| `t` | Save or remove current track from library |
| `S` | Copy current track URL |
| `Q` | Show the runtime queue |
| `f` | Seek forward |
| `B` | Seek backward |
| `q` | Hide the browser buffer |

Use `M-x imenu` in Home, Explore, or Library to jump between rendered
sections.

Inside the now-playing child frame:

| Key | Action |
| --- | --- |
| `SPC` | Toggle pause |
| `n` | Next track |
| `p` | Previous track |
| `r` | Cycle repeat mode |
| `s` | Toggle shuffle |
| `A` | Open current-track actions |
| `l` | Like or unlike the current track |
| `d` | Dislike or undislike the current track |
| `R` | Start mix from the current track |
| `P` | Add current track to a playlist |
| `t` | Save or remove current track from library |
| `S` | Copy current track URL |
| `Q` | Show the runtime queue |
| `q` | Hide the child frame |

## Helper Contract

The CLI surface is:

```text
ytm-radio-helper auth check --auth FILE
ytm-radio-helper auth login-window --output FILE [--browser BROWSER] [--profile-dir DIR] [--port N] [--timeout-secs N] [--restart-running]
ytm-radio-helper browse home --auth FILE [--limit N] [--initial-only]
ytm-radio-helper browse home --mock [--limit N] [--initial-only]
ytm-radio-helper browse explore|library|library-songs|library-albums|library-artists|library-playlists|liked --auth FILE [--limit N]
ytm-radio-helper browse explore|library|library-songs|library-albums|library-artists|library-playlists|liked --mock [--limit N]
ytm-radio-helper browse-id BROWSE_ID --auth FILE [--params PARAMS] [--limit N]
ytm-radio-helper browse-id BROWSE_ID --mock [--params PARAMS] [--limit N]
ytm-radio-helper continuation TOKEN --auth FILE [--limit N]
ytm-radio-helper continuation TOKEN --mock [--limit N]
ytm-radio-helper search QUERY --auth FILE [--limit N]
ytm-radio-helper search QUERY --mock [--limit N]
ytm-radio-helper rate VIDEO_ID like|dislike|indifferent --auth FILE
ytm-radio-helper rate VIDEO_ID like|dislike|indifferent --mock
ytm-radio-helper radio VIDEO_ID --auth FILE [--limit N]
ytm-radio-helper radio VIDEO_ID --mock [--limit N]
ytm-radio-helper playlist-options VIDEO_ID --auth FILE
ytm-radio-helper playlist-options VIDEO_ID --mock
ytm-radio-helper add-to-playlist VIDEO_ID PLAYLIST_ID --auth FILE
ytm-radio-helper add-to-playlist VIDEO_ID PLAYLIST_ID --mock
ytm-radio-helper library VIDEO_ID toggle|save|remove --auth FILE
ytm-radio-helper library VIDEO_ID toggle|save|remove --mock
```

For `home`, `explore`, and `library`, the helper preserves YouTube Music
sections and returns each section as a source. `browse home --initial-only`
returns only the first Home page plus a continuation token. `continuation TOKEN`
loads the next Home section page. The limit applies per section.
The explicit library subtargets return focused sources for songs, albums,
artists, playlists, and liked music. `search` returns a source containing mixed
result items.
`browse-id` is used internally by the Emacs UI to expand albums, artists, and
playlists without sending YouTube Music-only pages through yt-dlp. When YouTube
Music returns endpoint `params`, the Emacs UI passes them through `--params`
because some playlist and mix pages reject a bare `browseId`.
`rate` is used by the current-track actions menu and maps to YouTube Music's
like, dislike, and remove-rating endpoints.
`VIDEO_ID` arguments must be 11-character YouTube video ids.
`radio` loads a YouTube Music mix queue from a seed video id.
`playlist-options` returns writable playlists for a video, and
`add-to-playlist` adds the video to the selected playlist.
`library` toggles, saves, or removes the current song through YouTube Music
feedback tokens fetched by the helper.

URL imports remain a general `yt-dlp` compatibility path. They do not store
YouTube Music menu tokens, but actions that only need a video id, such as
like, dislike, radio, and add-to-playlist, can still work when the imported
track URL or id contains a YouTube video id. Library save/remove fetches the
needed token at action time through the helper.

Responses use a stable envelope:

```json
{
  "ok": true,
  "schema": 1,
  "data": {
    "sources": []
  },
  "warnings": []
}
```

## Login

There is no separate login command in normal use. When `M-x ytm-radio` opens an
uncached account-backed view, or when Home, Explore, Library, Search, or a
detail page needs account access, ytm-radio opens the browser login flow
automatically. After login succeeds, ytm-radio resumes the action that required
account access.

If the helper reports that an existing auth file is rejected, for example with
HTTP 401 Unauthorized or HTTP 403 Forbidden, ytm-radio clears account-derived
cache, opens the same login flow, and retries the original action after login.

ytm-radio opens the login browser at `https://music.youtube.com` with the
browser's normal profile by default. Sign in there if needed. The helper waits
for the logged-in YouTube Music page to expose cookies and page context, then
writes the auth JSON.

The login browser must be started with a local DevTools endpoint. If the
browser is already running without that endpoint, ytm-radio asks before
restarting it once. This avoids launching a second Dia instance while still
letting the existing normal browser profile be reused after restart.

The login flow:

1. opens the login browser with a local DevTools endpoint;
2. waits for sign-in to finish;
3. reads YouTube Music cookies and `ytcfg` page context through DevTools;
4. writes a private JSON file with mode `0600` on Unix;
5. clears the helper bootstrap cache;
6. refreshes Home asynchronously.

The default output is:

```text
~/.ytm-radio/auth.json
```

Runtime data defaults to `~/.ytm-radio/`: `auth.json` stores the helper session,
`bootstrap-cache.json` stores non-secret YouTube Music client bootstrap data,
`response-cache/` stores short-lived helper API responses scoped by account,
`state.eld` stores imported sources and the last track, and `covers/` caches
cover images. The helper refreshes `bootstrap-cache.json` automatically when it
is missing, invalid, or older than 12 hours. Helper API responses use short TTLs
and are cleared after login refresh. If default
`~/.emacs.d/ytm-radio/auth.json` or `state.eld` files already exist from an
older checkout, ytm-radio copies them into the new directory on first startup.

By default, ytm-radio opens the system default browser when that browser
supports the Chromium DevTools login flow. On macOS this uses the default
application for `https://` URLs. On Linux this uses the default
`x-scheme-handler/https` desktop entry.

Set a preferred login browser when the default browser is unsupported or when
you want a specific browser. Use `chrome`, `brave`, `edge`, `chromium`, `dia`,
or an executable path:

```elisp
(setq ytm-radio-helper-login-browser "chrome")
```

By default, login uses the browser's normal profile. If you want an isolated
login profile instead, set:

```elisp
(setq ytm-radio-helper-login-profile-directory
      "~/.ytm-radio/login-profile/")
```

The default local DevTools port is `29317`:

```elisp
(setq ytm-radio-helper-login-cdp-port 29317)
```

The default login timeout is 180 seconds:

```elisp
(setq ytm-radio-helper-login-timeout 180)
```

For deterministic local testing without account access:

```elisp
(setq ytm-radio-helper-use-mock-data t)
```

Then open Home, Explore, Library, Search, or a detail page. Mock mode does not
require an auth file.

The default file is reused automatically in future Emacs sessions. For a
custom location:

```elisp
(setq ytm-radio-helper-auth-file
      "~/.ytm-radio/custom-auth.json")
```

The auth file may contain account session material. Keep it out of git and
never store its contents in Emacs state.

Set `YTM_RADIO_TIMINGS=1` before starting Emacs to make the Rust helper print
bootstrap and YouTube Music request timings to stderr. Successful helper stdout
remains machine-readable JSON.

## Protocol References

- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [ytmusicapi browser authentication](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/auth/browser.py)
- [ytmusicapi browsing requests](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/mixins/browsing.py)

## URL Cookies

These options are for `yt-dlp` media discovery and mpv playback only. They are
not used for ytm-radio account login.

Configure discovery-time `yt-dlp` options:

```elisp
(setq ytm-radio-yt-dlp-extra-args
      '("--cookies-from-browser" "chrome"))
```

Configure mpv's ytdl hook:

```elisp
(setq ytm-radio-ytdl-raw-options
      '("cookies-from-browser=chrome"))
```

ytm-radio asks mpv's ytdl hook for audio-only formats by default. This reduces
startup work for YouTube Music playback:

```elisp
(setq ytm-radio-mpv-ytdl-format "bestaudio/best")
```

Set it to nil to use mpv's default ytdl format selection:

```elisp
(setq ytm-radio-mpv-ytdl-format nil)
```

ytm-radio enables a conservative mpv network cache by default for long YouTube
Music tracks while avoiding an initial cache pause:

```elisp
(setq ytm-radio-mpv-network-cache-args
      '("--cache=yes"
        "--cache-pause=no"
        "--demuxer-readahead-secs=60"
        "--demuxer-max-bytes=256MiB"))
```

When playback starts, ytm-radio also pre-resolves the next track's direct audio
stream URL in the background.  This keeps browsing responsive while allowing the
next track to start faster when the cached stream URL is still valid:

```elisp
(setq ytm-radio-stream-prefetch-limit 1)
```

Set `ytm-radio-mpv-extra-args` to override these values when needed. Extra args
are passed after the default playback args, so mpv's later option wins.

## Development

Run all deterministic checks:

```sh
make check
```

This byte-compiles Elisp, runs ERT, checkdoc, package-lint, Rust formatting,
Clippy, and unit tests.

## License

ytm-radio is licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).
