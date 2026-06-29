# ytm-radio Behavioral Spec

This file records narrow behavioral contracts that are easy to regress but too
detailed for the PRD.

## Interface Scope

ytm-radio renders Emacs-native `special-mode` buffers plus optional
now-playing side-window and child-frame surfaces. It does not render, expose,
or test a standalone terminal TUI outside Emacs.

## Account State Markers

Track rating state is indexed at runtime by YouTube video id. Helper source and
item fields seed that index, and mutation results override older source
snapshots without rewriting every cached payload. Saved/library state
(`in-library`) is not a substitute for a thumbs-up rating.

Helper `like-status` fields distinguish unknown state from a known unrated
state. If the helper cannot determine rating state, it omits `like-status`.
If the helper determines that a track is unrated, it returns `like-status:
null`. UI refreshes must preserve cached rating markers when `like-status` is
absent, and clear a cached marker only when the field is present with a null
value.

Track rating markers:

- `like` is rendered as a Material Design thumb-up icon from Nerd Icons:
  `nf-md-thumb_up`.
- `dislike` is rendered as a Material Design thumb-down icon from Nerd Icons:
  `nf-md-thumb_down`.
- If Nerd Icons is unavailable, the fallback glyphs are `▲` for like and `▼`
  for dislike.
- Browser rows and now-playing title rows must not render rating state as the
  words `liked` or `disliked`.
- The rating marker is appended directly after the visible track title with one
  separating space.
- In browser rows, the marker is not part of the title button. It must not carry
  button, action, or follow-link text properties.
- Icon text properties from Nerd Icons, such as the icon face, must be
  preserved on the marker.

Visibility rules:

- Home, Explore, Search, Library Songs, Library Albums/Artists/Playlists where
  track rows appear, detail track lists, queue rows, and now-playing should show
  rating markers when `:like-status` is known on that row or another cached row
  for the same video id.
- Liked Music uses the same rating markers as other track views. This keeps
  explicit like and dislike state visible even when the source title already
  identifies the collection as Liked Music.
- Library album and playlist bookmark markers remain hidden inside Library
  views to avoid redundant saved-state markers.

The Library root contains songs, albums, artists, and playlists, but not the
standalone Liked Music source. The browser does not expose a command or key for
importing that source. The helper may retain its independent `liked` target as
a protocol capability.

Action labels and messages may use words such as `liked`, `disliked`, `Like`,
and `Dislike`; this icon contract applies only to persistent row/title rating
markers.

## UI Line Wrapping

Browser and now-playing buffers use non-wrapping rows. Long track, artist,
album, playlist, detail, queue, and control rows truncate horizontally in narrow
windows instead of visually wrapping onto continuation screen lines.

## Now-Playing Child Frame

The now-playing child frame must not display a frame tab bar or buffer tab line,
regardless of the user's global tab configuration.

The `child-frame` display style uses a graphical child frame on graphical
displays. In terminal Emacs, it uses a TTY child frame only when
`tty-child-frames` is available. If terminal child-frame creation fails or the
feature is unavailable, ytm-radio must fall back to a regular now-playing buffer.
When terminal child-frame rendering has no image support, it omits the cover
row instead of showing a textual `[cover]` placeholder.

Cover art defines the child-frame width together with narrow visual side
padding. That padding may account for Emacs image/text edge rendering instead
of being mathematically symmetric, but it must remain small and deterministic.

Metadata, progress, and playback controls are centered against the same
child-frame body width. Text rows reserve the cover side padding as overflow
guard space so a rating marker appended to the title stays on the title line.

## Transient Menu State

The current-track transient menu shows stateful action state in the action
labels. Repeat uses `[ ]`, `[A]`, and `[1]` for off, all, and one. Shuffle,
like, dislike, and library use `[ ]` and `[✔]`. Inactive state tokens use the
`shadow` face; active state tokens use `transient-value`.

## Now-Playing Side Window

The `side-window` display style uses a top Emacs side window in both graphical
and terminal frames. It must not require `display-graphic-p`; terminal rendering
uses text/icon fallbacks for unavailable images.

Side-window content renders on one row. When the row is too narrow, ytm-radio
keeps track identity and progress visible and hides playback controls instead
of wrapping into additional content rows. Extra configured height is inert
padding.

## Detail Account Mutations

Detail library and subscription mutations return refreshed detail sources from
the already-fetched detail response plus the requested target account state.
After YouTube Music accepts the mutation request, the helper must not wait for a
second detail fetch to verify eventual consistency.

When a detail header is synthesized from an opener item, positive account state
from either the helper source or the opener item is preserved. A saved album or
playlist card must therefore enter a detail page with a saved bookmark marker
even if the helper detail header does not expose reliable library state.

After a detail library or subscription mutation succeeds, the returned target
state must be indexed under matching browse and playlist ids. Going back to
Home, Explore, or Library must resolve stale opener/list snapshots through that
index and show the same state as the detail header.

Detail header bodies are not enterable sections. Pressing `RET` on ordinary
header text must not open a new view that only contains the same header image
and account action; `RET` on real text buttons still runs that button.

## Playback

Selecting a song from the browser with `RET` must start playback immediately.
When ytm-radio reuses an existing mpv IPC process and sends `loadfile`, it must
also clear mpv's pause state so a previously paused player does not leave the
newly selected song loaded but silent.

## Home Continuation

Home continuation tokens are durable state. Cached Home sections without a
known continuation state come from older state files and should trigger one
fresh Home load so lazy loading can recover the next-page token.

## Helper Network Requests

The helper owns bootstrap and response cache locations. Explicit Emacs refresh
commands pass `--fresh`; Elisp never deletes helper cache paths directly.
Successful account mutations invalidate cached API responses before the helper
exits. A successful browser login invalidates both bootstrap and response
caches associated with the auth path.

Both successful and failed helper commands write versioned JSON envelopes to
stdout. Failed commands exit non-zero and include `code`, `message`,
`retryable`, and `auth-required` fields. Emacs decides whether to start login
from `auth-required`, not by matching the message text. Human-readable helper
diagnostics remain on stderr. Help is a successful helper command and returns
its usage text inside the versioned data envelope.

Error code, retryability, and authentication metadata are assigned explicitly
at the error source. They must not be inferred from human-readable error text.

The Rust helper owns YouTube Music HTTP requests. A read-only YouTubeI request
that fails before any HTTP response is received is treated as a transient send
failure and retried twice with short backoff. Mutation requests are sent once;
repeating a request whose response was lost could apply an action twice. HTTP
error responses are not retried because they may represent account, auth, or
request-shape problems.

When retried read requests still exhaust all attempts, the helper error must
include the underlying error source chain and the attempt count so the Emacs
message can distinguish DNS, proxy, TLS, timeout, and connection failures.
