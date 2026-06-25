# Current Track Actions

ytm-radio now treats the currently playing song as its own action target.  The
browser point may be on a search result, album, artist, or section heading, so
mixing point actions with playback actions would make shortcuts ambiguous.

The current-track entry point is a `transient` prefix instead of a
`completing-read` menu.  These actions are high-frequency controls, and a
transient keeps direct key hints visible while still allowing each action to
remain a normal command.  `A` opens the menu in both ytm-radio buffers, while
`l` and `d` are direct bindings for like and dislike.

The first action set deliberately follows the subset that can be implemented
reliably today: playback controls, like/dislike, sharing, and local queue
updates.  Save-to-library and add-to-playlist require additional YouTube Music
menu token parsing, so they should be added only after the helper can expose
those tokens as structured data.
