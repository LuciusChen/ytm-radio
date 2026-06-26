# Browser Login Window

Superseded note: `010-chrome-login-profile.md` adds a Chrome-specific automatic
isolated profile because Chrome 136 no longer exposes remote debugging for the
default Chrome data directory.

## Context

ytm-radio first tried several authentication paths: importing cookies through
yt-dlp, copying request headers, and a Dia-specific DevTools restart flow. That
made the UX hard to explain and produced browser-specific failure modes before
users reached the actual product.

The first replacement used a dedicated browser profile by default. That avoided
touching the user's normal browser session, but it also meant users with an
already logged-in default browser saw a fresh empty profile instead of their
real YouTube Music account.

The project does not yet have compatibility obligations for existing users, so
keeping fallback auth paths would preserve complexity without protecting a real
installed base.

## Decision

Use one supported account-auth workflow:

- `M-x ytm-radio-login` opens the system default browser when it supports the
  Chromium DevTools login flow;
- the default path uses the browser's normal profile so an existing YouTube
  Music login can be reused when the browser can be started with DevTools;
- an isolated profile remains available through
  `ytm-radio-helper-login-profile-directory` for users who want one;
- the Rust helper waits for the user to sign in to YouTube Music;
- when the browser is already running without DevTools, Emacs asks before
  retrying with a one-shot browser restart;
- the helper reads cookies and YouTube Music page context through DevTools;
- the helper writes the private auth file and exits;
- Emacs clears account-derived cache and reloads Home.

Remove browser-cookie database import, copied-header import, and Dia-specific
restart commands from the public CLI and Emacs API.

## Why

The normal browser profile is the least surprising default: if the user already
uses Dia or another supported browser for YouTube Music, login should not start
from an empty profile.

DevTools still requires the browser process to be launched with a remote
debugging port. If the browser is already running without that port, the helper
cannot attach to it retroactively. In that case the correct behavior is an
explicit restart confirmation, not silently falling back to another browser or
profile.

Using DevTools gives the helper the data that matters for YouTube Music:
authenticated cookies plus the page's current `ytcfg` account context. That is
closer to what the web app is using than a bare cookie export, and it keeps the
session material out of Emacs state.

One path is easier to diagnose, document, and test. Fallbacks can be added later
only if real users need them and the failure mode is known.

## Follow-up

Improve distribution so users do not need to build the Rust helper manually.
Revisit auth only after the browser login window has been tested against real
Chrome-family browsers and the remaining failures are concrete.
