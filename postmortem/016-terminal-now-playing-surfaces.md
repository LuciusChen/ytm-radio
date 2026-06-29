# Terminal Now-Playing Surfaces

## Context

ytm-radio originally treated terminal Emacs as a regular-buffer fallback for
now-playing. That kept playback usable, but it made terminal behavior feel like
a degraded path even after the side-window style was added. Emacs also added
TTY child-frame support in newer versions, so the old `display-graphic-p` gate
was too coarse: it rejected capable terminal frames and accepted no fallback if
the terminal later rejected child-frame creation.

## Decision

Keep `side-window` available in terminal Emacs because it is a normal Emacs
window managed by `display-buffer-in-side-window`. It uses text and icon
fallbacks when images are unavailable.

Let `child-frame` use terminal child frames only when Emacs reports
`tty-child-frames`. Keep the regular-buffer fallback for older Emacs versions,
terminals without support, and child-frame creation errors.

Graphical child-frame behavior remains the richer path for cover images,
pixel-sized layout, and drag-to-move. Terminal child frames reuse the text
now-playing render path and deliberately avoid the graphical drag behavior.

## Why

Side windows compose best with terminal Emacs because they reserve real layout
space and rely on ordinary window primitives. TTY child frames are useful when
available, but they are newer, terminal-dependent, and not guaranteed in every
non-graphical session.

Separating capability detection from rendering keeps the display-style contract
small: `side-window` works in terminal and graphical frames, `child-frame`
tries the best child-frame surface available, and regular buffers remain the
last-resort fallback.
