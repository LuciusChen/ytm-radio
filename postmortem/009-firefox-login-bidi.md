# Firefox Login Through WebDriver BiDi

Firefox users should not have to install a Chromium-based browser only to sign
in to YouTube Music. The earlier login helper only supported Chromium DevTools,
so a system default Firefox browser failed before opening the login window.

The helper now treats browser automation as protocol-specific. Chromium-based
browsers continue to use DevTools. Firefox uses WebDriver BiDi, which provides
the two capabilities the login flow needs: reading cookies from the browser
session and evaluating a small script in the YouTube Music page to capture
session context.

We deliberately did not read Firefox cookie databases. That would cross the
helper boundary, duplicate browser-specific storage and encryption behavior,
and make locked or profile-specific databases a long-term support problem.
Keeping Firefox on the browser's own remote-control protocol preserves the
short-lived helper model and keeps session material flowing through the same
auth file path as Chromium login.

The main operational limitation is the same class of issue as Chromium: an
already-running browser that was not started with the helper's remote-control
port cannot be attached retroactively. Users can close Firefox before login or
configure an isolated profile directory so ytm-radio starts a separate Firefox
instance.
