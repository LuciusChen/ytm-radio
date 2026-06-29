# Single-Row Side-Window Layout

## Context

The side-window now-playing view is meant to be a compact control strip, not a
second full player. A multi-row layout makes narrow terminal frames more
readable, but it also changes the side window from a strip into a panel and
competes with the browser buffer for vertical space.

## Decision

Keep side-window content on a single row. Render track identity first and
progress second. Render playback controls only when enough horizontal space
remains; otherwise hide those controls instead of wrapping.

Additional configured side-window height creates inert padding rows. It does
not add more content.

## Why

Single-row behavior keeps the side window predictable and compact across
graphical and terminal frames. Hiding controls under width pressure preserves
the most useful passive information, while the same commands remain available
from key bindings and the transient menu.
