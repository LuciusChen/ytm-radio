# Variable-Height Image Slices

## Context

The browser originally adapted telega's technique of displaying one image as
two slices on adjacent text rows. That case has one seam and two deliberately
equal row slots, so a padded default font height plus a one-pixel overlap was a
reasonable workaround for mixed Latin and CJK text.

Detail headers extended the same idea to six or more rows. They reused one
height for every row and derived later slice offsets as `row * height - 1`.
That did not actually model a multirow layout: fallback fonts can give each row
a different height, and subtracting one only once overlaps the first boundary
while later boundaries drift. The final source pixel was also left unused.

## Decision

Extract the general mechanism into `image-slice.el`, with no ytm-radio state or
rendering dependency. Its layout contract accepts one `(HEIGHT . ASCENT)` metric
per row. Every slice offset is the cumulative height of the preceding rows, so
two rows are just the smallest instance of the same model rather than a special
coordinate formula.

The first extraction measured only the height of the font selected for each
glyph. A graphical smoke test disproved that model. Face height, boxes, raised
content, Emoji composition, and the default-face glyphs surrounding the cell all
participate in Emacs's final line box. More importantly, Emacs calculates a
screen line as `max(ascent) + max(descent)`. An image with `:ascent 'center` can
therefore enlarge a line even when its height equals the text height, leaving a
background strip between slices.

The library now asks Emacs's own layout engine for the rendered height of each
complete row with `buffer-text-pixel-size`. A second top-aligned space probe
recovers that row's ascent. `image-slice-row` copies the image descriptor with
the corresponding ascent percentage, so the image and text share a baseline.
Callers still supply a minimum height; extra height is split above and below the
measured content.

Adjacent rows use `line-height` set to `t`, which is Emacs's mechanism for
tiling image slices, while ytm-radio also fixes its buffer-local `line-spacing`
at zero because graphical backends do not treat nonzero spacing consistently.
Multirow detail covers therefore use disjoint slices with zero overlap and
cover the entire source image exactly. The generic API supports cumulative
overlap for renderers that need it, but ytm-radio retains that workaround only
for its already established two-row thumbnail layout. Those thumbnails create
their fixed SVG canvas with `image-slice-source-height`, so the repeated boundary
pixel does not rescale a taller source canvas.

The source canvas, displayed image, and slice coordinates use the same one-to-one
pixel space. The first extraction instead combined integer slice coordinates
with font-relative image dimensions. That appeared correct with an unremapped
default face, but a larger buffer-local face scaled the whole image while the
slice coordinates stayed unchanged. The visible block became wider than it was
tall and the final source rows were never displayed. Font-relative dimensions
remain useful for ordinary unsliced images, but not for an exact pixel canvas
whose row layout is rebuilt when the buffer font changes.

## Why

Using the tallest font height for the entire block would avoid some clipping,
but it would add unnecessary height to every row and would still ignore baseline
geometry. A fixed padding ratio is useful as a fallback, not as proof that an
arbitrary face, box, image, or fallback glyph fits. Encoding a forced total line
height is also insufficient: Emacs will not shrink a line below the independent
maximum ascent and descent of its visible contents.

Keeping the extraction image- and application-agnostic gives the coordinate
rules one testable owner. ytm-radio remains responsible for building its title,
metadata, blank, and action rows and for creating an SVG canvas whose height is
the sum of their measurements.

## Known Limitation

Exact line-box and baseline measurement depends on a live graphical window.
Before that context exists, `image-slice.el` falls back to per-font height and the
caller's minimum, without claiming an exact ascent. ytm-radio keeps its 25
percent padded default for this path, displays the browser before measuring its
detail rows, and rerenders covers after text-scale changes. GUI smoke tests remain
required because structural display-property tests cannot reveal scaling or
baseline gaps.
