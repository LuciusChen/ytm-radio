# Helper Release Installer

## Context

The Rust helper is required for account-backed YouTube Music browsing, login,
and account actions. Before this change, a second machine needed a Rust
toolchain and a local `cargo build --manifest-path helper/Cargo.toml` before
`M-x ytm-radio` could use account-backed features. That made the helper feel
like a development artifact rather than a normal runtime dependency.

## Decision

ytm-radio provides `M-x ytm-radio-install-helper`, which downloads a
platform-specific helper binary from GitHub Releases into
`~/.ytm-radio/bin/ytm-radio-helper`. The default in-repository helper path is
still supported for development. When that default path is missing, ytm-radio
falls back to the installed release helper.

When account-backed data first needs the helper and neither the in-repository
debug helper nor the installed release helper is executable, ytm-radio offers to
download the matching helper release. If the user confirms, the same installer
path downloads the helper and the original helper-backed action continues.

The helper remains an external process, not an Emacs dynamic module. This keeps
the account boundary unchanged: Emacs still talks to the helper through JSON
stdout, and the helper can be built, signed, inspected, or replaced
independently from the Emacs Lisp package.

Downloads happen only through the explicit install command or an interactive
first-use confirmation prompt. Opening ytm-radio, browsing, or playing does not
silently fetch executable code.

## Consequences

Normal users do not need Rust just to use account-backed features. Developers
can continue to use the local debug helper by running Cargo from the checkout.

Release quality now depends on publishing helper assets with names that match
the installer target mapping, such as
`ytm-radio-helper-aarch64-apple-darwin` and
`ytm-radio-helper-x86_64-unknown-linux-gnu`.
