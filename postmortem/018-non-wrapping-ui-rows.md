# Non-Wrapping UI Rows

## Context

ytm-radio renders many YouTube Music entities as single logical rows: tracks,
albums, playlists, artists, detail entries, queue entries, and now-playing
metadata. In narrow frames, Emacs visual wrapping can turn one logical row into
several screen lines, which makes lists hard to scan and breaks the compact UI
shape.

## Decision

Disable automatic visual line wrapping in ytm-radio UI buffers. Browser and
now-playing buffers set `truncate-lines` and clear `word-wrap`, and buffer
access reapplies those settings so later local changes do not leave the UI in a
wrapping state.

## Why

The row renderer already treats each item as a single logical line. Keeping the
non-wrapping rule at the major-mode/buffer boundary applies consistently across
Home, Explore, Library, Search, detail, queue, child-frame, side-window, and
regular now-playing surfaces without duplicating truncation logic in every row
renderer.
