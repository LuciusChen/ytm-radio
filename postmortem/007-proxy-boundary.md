# Proxy Boundary

## Context

Users may need ytm-radio to work behind a local proxy, especially when YouTube
Music is unreliable or unavailable on the direct network path. Before this
change, proxy support was possible only by manually coordinating
`ytm-radio-yt-dlp-extra-args`, `ytm-radio-ytdl-raw-options`, and
`ytm-radio-mpv-extra-args`. The Rust helper had no proxy path at all, so
account-backed Home, Search, Library, and current-track account actions could
still bypass the configured media proxy.

## Decision

ytm-radio uses one first-class `ytm-radio-proxy-url` setting. Elisp passes it to
yt-dlp metadata and stream resolution, mpv's ytdl hook, mpv direct transport
when the proxy is HTTP or HTTPS, and the Rust helper's YouTube Music request
commands. The helper maps the value to reqwest's all-protocol proxy support,
including SOCKS through the reqwest `socks` feature.

The browser login window intentionally does not receive this setting. It remains
owned by the browser and system proxy configuration because the login workflow
also talks to local DevTools endpoints, and ytm-radio should not manage browser
network policy until there is a clear user workflow for that.

## Consequences

Users get one Emacs setting for the normal account and playback paths instead
of several backend-specific knobs. Existing low-level knobs remain available for
advanced overrides.

SOCKS proxy support has one playback caveat: mpv direct media URL playback may
not preserve SOCKS routing. To avoid bypassing the configured proxy, ytm-radio
does not use cached direct stream URLs when a non-HTTP proxy is configured, and
it lets mpv's ytdl hook handle extraction and playback instead.
