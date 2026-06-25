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
- Users who prefer a compact now-playing child frame for artwork and transport
  controls while continuing to work in other buffers.

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
- Keep the now-playing child frame focused on cover art, title, artist,
  progress, and compact playback-mode controls.
- Treat the currently playing track as a first-class action target, separate
  from browser point, so account actions and local queue actions remain
  predictable when point is on a search result, section, album, or artist.
- Keep account access short-lived and outside Elisp, while making the browser
  login handoff automatic when account-backed views require it.

## Non-goals

- Do not embed the full YouTube Music web app.
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
- The now-playing child frame should not steal focus during track changes.
- The child frame should resize deterministically from current track/player
  state and avoid speculative layout compensation.

## Technical Requirements

- Elisp owns local catalog state, runtime queue state, UI rendering, user
  commands, and mpv IPC.
- `yt-dlp` owns URL metadata discovery and mpv's ytdl media extraction path.
- The Rust helper owns YouTube Music account requests, account mutations, the
  browser login window, and helper JSON envelopes. Elisp may choose targets and
  update local display state, but it must not persist YouTube Music feedback
  tokens or duplicate Innertube request assembly.
- Helper stdout must remain machine-readable JSON; diagnostics belong on
  stderr.
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
