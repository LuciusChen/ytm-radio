# Chrome Login Profile

Chrome 136 changed remote debugging behavior: `--remote-debugging-port` is no
longer honored for the default Chrome data directory. ytm-radio's previous login
default used the browser's normal profile, so a closed Chrome could still launch
without exposing the DevTools endpoint that the helper waits for.

ytm-radio now defaults `ytm-radio-helper-login-profile-directory` to an isolated
profile under the ytm-radio data directory. This keeps the helper on Chrome's
supported DevTools path, avoids interfering with the user's daily browser
profile, and still lets users opt into a normal profile by setting the variable
to nil for browsers that support it.
