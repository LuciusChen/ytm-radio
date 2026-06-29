# Liked Music Separation

## Context

Library previously fetched and rendered Liked Music alongside songs, albums,
artists, and playlists. That made the standalone liked-songs collection look
like a normal Library subsection and encouraged the row renderer to suppress
rating markers based on the source title rather than the track's explicit
account state.

The helper exposes Liked Music as its own low-level target, but the browser does
not need a second Library-like navigation concept for it.

## Decision

The helper's Library aggregate fetches songs, albums, artists, and playlists,
but not Liked Music. Elisp also excludes previously cached Liked Music sources
from the Library root so durable state from older versions does not restore the
old layout.

The browser removes the dedicated Liked Music import command and its `i` key.
The helper may retain the independently addressable target as a protocol
capability. If a legacy cached source is rendered, its rows use the same
explicit like and dislike markers as tracks in other views.

## Consequences

Library no longer presents a redundant Liked Music section, and the browser no
longer offers an import command whose result has no visible destination.
Explicit rating state remains visible consistently across rendered track views.
