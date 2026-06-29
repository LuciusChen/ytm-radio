# Helper Release Integrity

## Context

The installer downloaded from the moving `latest` release URL while Elisp
required one exact helper version. After a newer helper release, an older Elisp
package could therefore download a binary it would immediately reject.

The installer also replaced the executable after an HTTPS download without
checking a companion published digest. The release workflow did not run
the helper formatting, lint, and test gates before uploading binaries.

## Decision

Helper downloads use the version declared by the Elisp package. Every release
asset has a companion `.sha256` file, and the installer verifies that digest
before making the downloaded file executable or replacing the installed
helper.

The release workflow runs `cargo fmt`, clippy with warnings denied, and the
locked helper test suite before any platform build job can upload assets.

## Consequences

Elisp and helper installation now select the same release deterministically.
A missing or mismatched checksum prevents installation and leaves the previous
binary untouched. Publishing a usable release requires both the platform asset
and its checksum file.
