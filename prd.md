# ytm-radio PRD

## Purpose

ytm-radio is an Emacs-native YouTube Music audio client. It keeps browsing,
selection, and playback control inside Emacs while delegating web protocol
compatibility and media playback to external tools.

The product should feel like an Emacs buffer first, not a browser embedded in
Emacs. It should still preserve enough of YouTube Music's structure that Home,
Explore, Library, Search, detail pages, and now-playing state are recognizable
and useful.

## Users

- Emacs users who want keyboard-first YouTube Music playback.
- Users who want a guided YouTube Music login flow without copying headers or
  exposing raw cookies to Emacs state.
- Users who prefer a compact now-playing child frame or frame-level side window
  for artwork, metadata, and transport controls while continuing to work in
  other buffers, including terminal Emacs users.

## Goals

- Provide one main entry point, `M-x ytm-radio`, for browsing and playback.
- Render YouTube Music Home, Explore, Library, Search, and detail pages as
  structured `special-mode` buffers.
- Preserve mixed YouTube Music modules, including tracks, albums, artists,
  playlists, podcasts, and recommendation sections when the web response
  exposes them.
- Keep playback controls keyboard-first: open, play, pause, next, previous,
  seek, repeat, shuffle, share, queue viewing, current-song actions, and back
  navigation must be available without mouse interaction.
- Keep now-playing surfaces focused on cover art, title, artist, progress, and
  compact playback-mode controls.
- Treat the currently playing track as a first-class action target, separate
  from browser point, so account actions and local queue actions remain
  predictable when point is on a search result, section, album, or artist.
- Keep account access short-lived and outside Elisp, while making the browser
  login handoff automatic when account-backed views require it.

## Non-goals

- Do not embed the full YouTube Music web app.
- Do not build or support a standalone terminal TUI; the product UI is Emacs
  buffers, side windows, and supported child frames.
- Do not implement browser cookie database decryption in Rust.
- Do not support copied request-header auth or browser-cookie database import
  as fallback login paths.
- Do not add an Emacs dynamic module or Python helper.
- Do not make the Rust helper a resident service by default.
- Do not persist cookies, auth headers, process objects, sockets, timers, or
  IPC handles in Emacs durable state.

## User Experience Requirements

- Empty startup must show the browser shell and useful import actions, not a URL
  prompt.
- Opening an uncached account-backed view without auth should start the browser
  login flow automatically and resume the requested action after login.
- HTTP 401/403 and obsolete auth-source diagnostics should clear
  account-derived cache, start the same login flow, and retry the requested
  action after login.
- Root views should use the stable top-level vocabulary: Home, Explore, and
  Library. Search is a command-driven view entered with `/`, not a persistent
  top-level tab.
- The browser buffer should use `header-line-format` for the current view and
  lightweight loading status. The rendered buffer body should start with
  content, not a tab strip.
- Section rows should distinguish item type visually while keeping the title
  and metadata aligned for keyboard scanning.
- Item links should use text properties for actions and data; behavior must not
  depend on reparsing visible text.
- Opening a non-track item should expand the YouTube Music detail page when the
  helper can fetch it.
- Playing from a detail page, source, search result, or mix should establish a
  runtime queue that `next`, `previous`, and the queue view use consistently.
- Current-track actions should be fast to reach through direct bindings and a
  transient menu, while each action remains callable as a normal command.
- Browser refreshes should preserve point when possible and never park point at
  the end as a side effect of rendering.
- Now-playing refreshes should not steal focus during track changes.
- The now-playing child frame should keep cover art, metadata, progress, and
  playback controls compact, visually balanced, and independent from global tab
  UI.
- In terminal Emacs, the side-window now-playing style should remain available
  as a normal Emacs side window, using text/icon fallbacks for unavailable
  images.
- In terminal Emacs builds with `tty-child-frames`, the child-frame display
  style should use a TTY child frame. Older or incompatible terminal sessions
  should fall back to a regular buffer instead of failing.
- Mouse users should be able to drag the now-playing child frame without
  breaking keyboard-only operation or playback controls.
- The child frame should resize deterministically from current track/player
  state and avoid speculative layout compensation.
- The side-window now-playing style should appear once per frame instead of once
  per window, reserve layout space, and avoid unrelated tab-bar semantics.

## Technical Requirements

- Elisp owns local catalog state, runtime queue state, UI rendering, user
  commands, and mpv IPC.
- `yt-dlp` owns URL metadata discovery and mpv's ytdl media extraction path.
- The Rust helper owns YouTube Music account requests, account mutations, the
  browser login window, and helper JSON envelopes. Elisp may choose targets and
  update local display state, but it must not persist YouTube Music feedback
  tokens or duplicate Innertube request assembly.
- The browser login window may use Chromium DevTools or WebDriver BiDi for
  Firefox-family browsers, including Firefox and Zen. It must not read browser
  cookie databases directly.
- The helper may be built locally during development or installed as a
  platform-specific release binary. Emacs may download that binary through an
  explicit user command, but it must not silently download executable code while
  opening or browsing.
- A single optional proxy URL may be applied to helper account requests,
  `yt-dlp` discovery and prefetching, cover image downloads, and mpv playback
  paths. When the helper starts a Chromium-compatible login browser, the proxy
  is applied to that browser launch. ytm-radio does not rewrite Firefox or Zen
  profile preferences for WebDriver BiDi login, and it does not alter
  already-running browser sessions; those paths use browser or system proxy
  configuration.
- Helper stdout must remain machine-readable JSON; diagnostics belong on
  stderr.
- Helper failures must expose stable error codes and auth/retry metadata rather
  than requiring Elisp to classify diagnostic text.
- The Rust helper owns its bootstrap and response cache paths, explicit refresh
  bypass, and mutation invalidation. Elisp must not delete helper cache files
  directly.
- Helper schema versions are explicit, and unsupported schema versions must be
  rejected.
- Deterministic tests must not require live YouTube Music, browser cookies, or
  mpv.

## Documentation Requirements

- Update `README.md` when commands, key bindings, setup, configuration, or user
  workflows change.
- Update this PRD when product scope, major UX behavior, or boundary decisions
  change.
- Write a postmortem under `postmortem/` for non-obvious workflow,
  architecture, integration, rollback, or deferral decisions.
