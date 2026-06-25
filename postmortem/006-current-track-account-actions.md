# Current Track Account Actions

The current-track transient now includes YouTube Music account actions instead
of only local playback controls.  Aligning with Kaset means treating the active
song as an action target with a small service facade in Emacs and the actual
YouTube Music protocol work in the Rust helper.

The helper owns these account mutations because it already owns authenticated
YouTube Music requests.  Emacs builds command arguments, chooses completion
targets, and updates local playback state, but it does not assemble Innertube
request bodies or retain feedback tokens.  That keeps auth-sensitive protocol
details out of durable Emacs state and avoids splitting YouTube Music reverse
engineering across languages.

The first expanded set is:

- `rate`, which only needs a video id;
- `radio`, which uses the `next` endpoint with an `RDAMVM` seed playlist id and
  becomes a runtime queue, not a persisted source;
- `playlist-options` plus `add-to-playlist`, which ask YouTube Music for the
  account's writable playlist targets before mutating a playlist;
- `library`, which fetches the current song metadata, extracts a temporary
  feedback token, and immediately submits it.

The old ytr-style URL import still has value as a compatibility path for
arbitrary YouTube URLs, but it is not a YouTube Music metadata import.  It now
runs asynchronously because `yt-dlp` can be slow enough to freeze Emacs.  Tracks
imported that way can participate in video-id based actions when their URL or
id exposes a video id.  They should not be expected to carry YouTube Music menu
tokens in state; library save/remove fetches those tokens at action time if
YouTube Music can provide them.

This split keeps the workflow responsive while making the action surface honest
about capability: URL import discovers playable media, and the account helper
performs authenticated YouTube Music operations.
