# Chrome Login Profile

Chrome 136 changed remote debugging behavior: `--remote-debugging-port` is no
longer honored for the default Chrome data directory. ytm-radio's previous login
default used the browser's normal profile, so a closed Chrome could still launch
without exposing the DevTools endpoint that the helper waits for.

The Rust helper now applies an automatic isolated profile only when the resolved
login browser is Chrome and no explicit profile directory was provided. The
automatic Chrome profile lives next to the auth file as `login-profile`. This
keeps Chrome on its supported DevTools path without forcing Dia, Firefox, or
other supported browsers into a fresh profile.

`ytm-radio-helper-login-profile-directory` remains an explicit override for
users who want a specific isolated profile for any supported browser. Leaving it
nil delegates profile selection to the helper's browser-specific defaults.
