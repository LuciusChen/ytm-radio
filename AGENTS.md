# AGENTS.md

This file is the local source of truth for AI-assisted changes in this
repository. It is adapted from `~/repos/coding-guidelines/general.md` and
`~/repos/coding-guidelines/elisp.md`, plus project-specific ytm-radio rules.

## Project Shape

- Keep the project small until real complexity appears. Prefer one clear file
  with well-named sections over several tiny files with unclear boundaries.
- Split modules only around stable responsibilities such as state, external
  process management, source fetching, helper protocol handling, or UI display.
- Do not add abstraction layers for hypothetical providers. Add a layer only
  when it removes current duplication or gives a real owner to a workflow.
- Do not create vague `utils`, `common`, or pass-through wrapper modules.
- Keep public commands thin: collect interactive input, validate it, call
  internal functions, and show feedback.
- Prefer stock Emacs primitives: `completing-read`, `special-mode`, text
  properties, `start-process`, `make-network-process`, standard timers, and
  standard hooks.

## Diagnosis Discipline

- Find the root cause before changing behavior. Be able to name the failing
  layer before patching timing, caching, rendering, or control flow.
- If one fix fails, narrow the hypothesis and gather more evidence.
- After two failed fixes on the same issue, stop patching and switch to
  diagnosis only.
- Fix the layer that owns the problem instead of compensating elsewhere.
- Keep experiments narrow. Prove a new direction with the smallest useful
  slice before expanding scope.

## Emacs Lisp Rules

- Every `.el` file uses lexical binding.
- Loading package files must not alter active editing behavior. Activation
  happens through explicit commands or user-enabled modes.
- Use the `ytm-radio-` prefix for public API and `ytm-radio--` for private
  helpers and private modes.
- Never call another package's private double-dash symbols.
- Public commands and user-facing modes need `;;;###autoload`.
- Do not autoload internal helpers, variables, or private modes.
- Public `defun`, `defmacro`, `defcustom`, and `defvar` forms must have
  docstrings.
- Docstring first lines must be complete sentences ending in a period.
- Argument names mentioned in docstrings should be uppercased.
- Use precise `defcustom :type` declarations and always set `:group`.
- Use `defvar-local` and `setq-local` for per-buffer state. Major modes must
  make their state buffer-local.
- Read-only UI buffers derive from `special-mode`.
- Use text properties for data-bearing annotations; use overlays only for
  ephemeral visuals.
- Build render buffers from structured state, not by reparsing visible text.
- Prefer `when-let*`, `if-let*`, `pcase`, and `pcase-let` for structured
  conditional binding and destructuring.
- Use `user-error` for user-caused problems such as missing external programs,
  invalid configuration, or empty catalogs.
- Use `error` for programmer bugs. Catch errors only at external process,
  optional display, or top-level helper protocol boundaries where recovery is
  meaningful.
- Require runtime dependencies explicitly, for example `(require 'cl-lib)`.
  Do not rely on transitive loading.
- Avoid `eval-when-compile` for dependencies needed at runtime.
- Before using a newer Emacs API, verify when it was introduced and do not
  exceed the declared Emacs baseline without updating package metadata and docs.

## MELPA / Package Rules

- Main package first line must be:
  `;;; ytm-radio.el --- Short description -*- lexical-binding: t; -*-`
- The package description must not contain "for Emacs" or the package name.
  Keep it under 60 characters.
- The main package file must include `;; Author:`, `;; URL:`, `;; Version:`,
  and `;; Package-Requires:`.
- `Package-Requires` must list all direct dependencies with minimum versions,
  including the declared Emacs baseline.
- Package metadata belongs in the main package file only. Split implementation
  files must not duplicate `Package-Requires`.
- Split implementation files still need formal license metadata, preferably
  `;; SPDX-License-Identifier:`.
- Keep required MELPA checklist attribution such as `;; Assisted-by: ...` in
  the main package file when tooling materially assisted the package.
- Every distributable `.el` file ends with `(provide 'feature)` and
  `;;; file.el ends here`.
- Run byte-compilation with zero warnings.
- Run `checkdoc` with zero warnings on distributable Elisp files.
- Run `package-lint` with zero warnings for MELPA/ELPA-style package changes.
  If `package-lint` is unavailable locally, say so explicitly in the final
  report.
- When using `package-lint` on split implementation files, configure the main
  file instead of duplicating package metadata.

## ytm-radio Boundaries

- Do not implement YouTube or YouTube Music reverse-engineering in Elisp.
  Treat `yt-dlp` and the Rust helper as compatibility boundaries.
- Account access belongs in the external Rust CLI under `helper/`. Do not add
  a Python helper or an Emacs dynamic module.
- Keep the helper short-lived by default: one command reads configuration,
  writes one JSON response to stdout, and exits.
- Delegate browser-cookie database compatibility and decryption to `yt-dlp`;
  do not duplicate browser-specific crypto in Rust.
- Version the helper JSON envelope. Emacs must reject unsupported schema
  versions instead of guessing.
- Cookie support must be explicit user configuration. Store browser/source
  options in Emacs configuration or state; store session material only in the
  dedicated helper auth file with private permissions.
- Never write cookie contents or auth headers to Emacs durable state, stdout,
  logs, fixtures, or test failure messages.
- Store durable state separately from process state. Do not persist process
  objects, sockets, timers, or IPC handles.
- Keep child-frame rendering deterministic from current track/player state.
  Do not derive behavior from the displayed buffer text.

## Rust Helper Rules

- Keep authentication details out of stdout, logs, fixtures, and test failure
  messages.
- Live network checks stay separate from deterministic unit tests.
- Run `cargo fmt --check`, `cargo clippy -- -D warnings`, and `cargo test`
  for helper changes.
- Helper command output must remain machine-readable JSON on stdout; diagnostic
  text belongs on stderr.

## Tests and Verification

- `make check` is the normal local verification path.
- For behavior depending on YouTube, YouTube Music, `yt-dlp`, browser cookies,
  or `mpv`, keep network/live checks separate from deterministic unit tests.
- Match test weight to change size. Use the smallest test that proves the
  behavior.
- For user-visible bug fixes, add or update a test that proves the regression
  unless an existing test already covers the real dispatch path.
- Tests must fail when the code is wrong. Avoid assertions that merely lock in
  implementation details.
- Read the changed diff before finalizing. Remove duplicated logic, dead code,
  and temporary diagnostics.

## Documentation Discipline

- User-visible changes must update user documentation in the same change when
  they affect commands, key bindings, defaults, configuration, setup, or
  workflows.
- Code is the source of truth. If code and docs diverge, fix docs immediately.
- Optimize Markdown for rendered reading, not source-width aesthetics. Do not
  rewrap unchanged prose just to satisfy a column width.
- When documentation is hard to read, improve structure with headings, focused
  bullets, or tables instead of source-only line wrapping.
