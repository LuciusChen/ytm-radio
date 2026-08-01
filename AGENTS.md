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
- A refactor must create net value in ownership, simplicity, robustness, code
  size, extensibility, or test quality. Moving code, renaming layers, or adding
  wrappers without making the system easier to understand is not enough.
- Improve the model before deduplicating syntax. Prefer simpler state, data
  flow, control flow, and ownership over a larger abstraction hierarchy.
- Treat stacks of one-use helpers, accessors, and pass-through wrappers as
  design debt. Inline trivial ladders or move the whole workflow to a coherent
  owner; do not hide the stack in a new module.
- Prefer boring, direct control flow over clever dispatch hierarchies.
- Remove unused private code completely. Keep compatibility shims only for a
  documented public compatibility requirement, under the owning package's
  private prefix, with tests and an explicit removal condition.
- Keep functions focused, but do not split them merely to satisfy a line-count
  target. Extract a helper when it owns a coherent calculation or side effect.
- Name helpers after what they compute or perform, not after the caller that
  happens to use them.
- Separate pure calculation from I/O, process control, buffer mutation, and
  other side effects where that makes the boundary testable.

## Module Boundary Discipline

- Move whole responsibilities, including their state, operations, validation,
  and relevant rendering or formatting. A file containing only glue while the
  original file still owns the behavior is not a completed extraction.
- Stop an extraction when cross-file declarations, pass-through wrappers, and
  navigation overhead exceed the ownership it clarifies.
- Imports, declarations, adapters, and protocol types must express a real
  boundary. Do not add declarations merely so a lower-level module can call
  upward or reach into another dependency's internals.
- Modularize incrementally: move the smallest coherent slice, compile it, and
  run focused tests before moving the next slice.
- An independently reusable library must not depend on ytm-radio state, UI, or
  private symbols. ytm-radio may adapt the library through its public API.

## Diagnosis Discipline

- Find the root cause before changing behavior. Be able to name the failing
  layer before patching timing, caching, rendering, or control flow.
- Do not present a plausible explanation as root cause. Mark it as a
  hypothesis until code inspection, a reproduction, or a failing test confirms
  the actual failing path.
- If one fix fails, narrow the hypothesis and gather more evidence. Do not
  stack another speculative patch on top.
- After two failed fixes on the same issue, stop patching and switch to
  diagnosis only until the failing path is confirmed.
- Fix the layer that owns the problem instead of compensating elsewhere.
- Keep experiments narrow. Prove a new direction with the smallest useful
  slice before expanding scope.
- For dispatcher bugs, test the real dispatch path: keymaps, buttons,
  commands, hooks, async callbacks, and public entry points. Helper-level tests
  are not enough when the bug is in routing.
- For user-visible bug fixes, prefer red before green: reproduce the failure in
  a test or a minimal live check, confirm it fails, then change behavior.
- Do not leave heuristic shortcuts, silent partial implementations, duplicated
  logic, or dead code introduced during diagnosis.
- Before changing a primary entry point, default action, or action menu, write
  down the intended resolution path and default behavior.
- For broad refactors, inspect all affected code, tests, documentation,
  postmortems, build rules, release paths, and relevant integrations before
  choosing the architecture.
- Inspect local evidence before asking questions. Ask only when uncertainty in
  scope, compatibility, naming, ownership, or stopping criteria would materially
  change the implementation; state the recommended answer and its tradeoff.
- Record important wrong-layer compensation, silent fallbacks, timing hacks,
  duplicated lookups, or swallowed internal failures as design debt without
  silently expanding the current task.
- Errors must surface. Do not turn internal failures into plausible defaults.
  Suppress an error only at an explicit external or optional-display boundary
  where absence is expected, recovery is meaningful, and the fallback is
  documented or tested.
- Structural display-property tests cannot prove graphical correctness. For
  image sizing, font fallback, baselines, child frames, and redisplay behavior,
  include a minimal live graphical reproduction when practical.

## Emacs Lisp Rules

- Every `.el` file uses lexical binding.
- Loading package files must not alter active editing behavior. Activation
  happens through explicit commands or user-enabled modes.
- Use the `ytm-radio-` prefix for public API and `ytm-radio--` for private
  helpers and private modes.
- The external image-slice dependency uses `image-slice-` for public API and
  `image-slice--` for private helpers. Its source and package-specific rules
  live in the independent image-slice repository, not in this repository.
- Never call another package's private double-dash symbols.
- Multi-word predicate names end in `-p`. Prefix intentionally unused
  arguments with `_`.
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
- Avoid deep `let` / `if` nesting. Prefer flat, linear control flow and early
  validation.
- Prefer `cl-loop` for non-trivial iteration and idiomatic primitives such as
  `vconcat` over reconstructed equivalents. Return predicate values directly.
- Prefer `let*`, `pcase-let`, alists, plists, or table-driven mappings for
  short-lived context. Reserve `cl-defstruct` or object-style layers for stable
  data crossing module or lifecycle boundaries.
- Use `user-error` for user-caused problems such as missing external programs,
  invalid configuration, or empty catalogs.
- Use `error` for programmer bugs. Catch errors only at external process,
  optional display, or top-level helper protocol boundaries where recovery is
  meaningful.
- Error messages state what is wrong, for example "Not connected", rather than
  an abstract requirement such as "Must be connected". Do not wrap a standard
  error unless the wrapper adds semantics named by its docstring.
- Require runtime dependencies explicitly, for example `(require 'cl-lib)`.
  Do not rely on transitive loading.
- Avoid `eval-when-compile` for dependencies needed at runtime.
- When an intentionally lazy or cyclic boundary leaves an owner unloaded at
  byte-compilation time, add precise `declare-function` or `defvar` declarations.
  Do not duplicate declarations after a mandatory top-level `require`.
- Load optional dependencies only at the point of use, document them separately
  from required dependencies, and report a clear boundary error when a required
  public API is missing. Do not silently downgrade to a private API.
- Avoid `with-eval-after-load` unless registering an optional integration at a
  clear package boundary.
- Before using a newer Emacs API, verify when it was introduced and do not
  exceed the declared Emacs baseline without updating package metadata and docs.

## Emacs UI and Workflow Rules

- Register buffer-local hooks from mode bodies with LOCAL set to `t`.
- Keep target resolution, action definitions, and action presentation separate.
  Menus, transient UIs, keymaps, and external action packages must share the
  same business-logic path.
- Prefer one clear entry point and consistent behavior over overlapping wrapper
  commands. Wrappers are acceptable only when they share resolution, action,
  and default-action models.
- Use one vocabulary for the same workflow across labels, help, errors, tests,
  documentation, and helper protocol fields.
- A preview must show the payload or state that will actually be executed,
  saved, sent, or applied.
- Validate before destroying user context. On local validation failure, keep
  point, buffer, window, and input state where the user can correct the problem.
- UI symmetry follows domain semantics. Do not copy controls, metadata, or
  layout between nearby views unless the underlying operation matches.
- Completion-at-point functions stay close to the Emacs protocol, return
  quickly, compose with `:exclusive 'no` when appropriate, and avoid synchronous
  work that can re-enter or block the UI.
- Add completion-at-point functions buffer-locally with LOCAL set to `t`.

## Image and Rendering Rules

- Treat source-image coordinates, displayed image dimensions, line-box height,
  and baseline ascent as separate quantities. Do not assume equal font height
  implies equal rendered row geometry.
- For pixel-addressed image slices, keep the source canvas, displayed image, and
  slice offsets in the same one-to-one pixel coordinate space. Do not combine
  integer slice coordinates with independently scaling font-relative dimensions.
- Measure mixed faces, CJK, Emoji, boxes, raised text, and embedded displays with
  Emacs's final layout engine when a live graphical window is available.
- Adjacent slices require buffer-local `line-spacing` zero, gapless newlines,
  and per-row ascent alignment. A one-pixel overlap is a narrow renderer
  workaround, not a substitute for correct multirow geometry.
- Preserve a deterministic terminal or hidden-buffer fallback, but do not claim
  it is pixel-exact without a graphical display context.

## MELPA / Package Rules

- Every independently installable package entry file uses:
  `;;; file.el --- Short description -*- lexical-binding: t; -*-`
- The package description must not contain "for Emacs" or the package name.
  Keep it under 60 characters.
- Each independently installable package entry file includes `;; Author:`,
  `;; URL:`, `;; Version:`, and `;; Package-Requires:`.
- `Package-Requires` must list all direct dependencies with minimum versions,
  including the declared Emacs baseline.
- Package metadata belongs in each package's entry file only. Split
  implementation files must not duplicate `Package-Requires`; a genuinely
  standalone package in the same repository is not a split implementation file.
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

## Structured Data and File Rules

- Do not transform JSON, Lisp data, command protocols, or other structured
  formats through brittle raw string insertion when syntax boundaries matter.
  Prefer parser-backed, token-aware, or top-level-form-aware transformations.
- Prioritize semantic correctness over aggressive rewriting. Do not introduce a
  full parser or object framework when a small boundary-aware change is enough.
- Every path that exports or persists files defines its encoding and a sensible
  default. Test content correctness and at least one encoding-sensitive case
  when changing that path.
- Durable state schemas and helper protocol envelopes are versioned contracts;
  reject unsupported versions instead of guessing.

## ytm-radio Boundaries

- Do not implement YouTube or YouTube Music reverse-engineering in Elisp.
  Treat `yt-dlp` and the Rust helper as compatibility boundaries.
- Account access belongs in the external Rust CLI under `helper/`. Do not add
  a Python helper or an Emacs dynamic module.
- Keep the helper short-lived by default: one command reads configuration,
  writes one JSON response to stdout, and exits.
- The supported account-auth workflow is a browser login window driven by
  `auth login-window` through Chromium DevTools or Firefox-family WebDriver
  BiDi. Do not add browser-cookie database import, copied-header import,
  Dia-specific restart commands, or other fallback auth paths unless the
  product decision changes.
- Do not duplicate browser-specific cookie database crypto in Rust.
- Version the helper JSON envelope. Emacs must reject unsupported schema
  versions instead of guessing.
- Store login browser options in Emacs configuration; store session material
  only in the dedicated helper auth file with private permissions.
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
- Do not add tests for copy, punctuation, separators, icons, padding, or other
  cosmetic presentation unless they carry a product, accessibility, action, or
  regression contract.
- Treat tests as part of the architecture budget. Keep tests for public
  workflows, real invariants, and meaningful edge cases; remove redundant tests
  that cannot distinguish broken behavior.
- Use varied inputs, boundary cases, and distinct expected values where a
  hard-coded implementation could otherwise satisfy the test.
- Search existing tests for the changed public or private path before adding a
  new test, and update affected expectations in the same change.
- Graphical behavior needs proportionate GUI smoke verification in addition to
  deterministic ERT; do not replace the deterministic suite with screenshots.
- Read the changed diff before finalizing. Remove duplicated logic, dead code,
  and temporary diagnostics.

## Documentation Discipline

- User-visible changes must update user documentation in the same change when
  they affect commands, key bindings, defaults, configuration, setup, or
  workflows. Use `README.md` for user operation and `prd.md` for product
  behavior, scope, and UX decisions.
- Code is the source of truth. If code and docs diverge, fix docs immediately.
- Optimize Markdown for rendered reading, not source-width aesthetics. Do not
  rewrap unchanged prose just to satisfy a column width.
- When documentation is hard to read, improve structure with headings, focused
  bullets, or tables instead of source-only line wrapping.
- For substantial README changes, make the opening explain what the project is,
  who it serves, what problem it solves, and the next installation or Quick
  Start action.
- Lead with concrete user outcomes before implementation detail. Avoid vague
  promotional claims, feature dumping, and unnecessary badges.
- Never invent commands, capabilities, compatibility, benchmarks, metrics, or
  trust signals. Verify them against code, manifests, tests, workflows, or
  release records and report what remains unverified.
- Keep documentation-only tasks documentation-only. Do not change code,
  configuration, CI, or dependencies merely to make a documentation claim true
  unless the user explicitly expands the task.

## Version, Changelog, and Release Discipline

- Keep Emacs, Rust, dependency, helper-protocol, and external-tool baselines
  explicit. Do not raise one silently; update build metadata, release metadata,
  user documentation, and the relevant postmortem when a newer baseline is
  required.
- When the project maintains release notes or a changelog, update it for
  release-relevant features, fixes, supported integrations, configuration,
  dependency, public API, or documented workflow changes. Internal mechanical
  refactors and test-only changes do not require an entry.
- Keep the next version unreleased until it is intentionally published or
  tagged. A commit or merge is not itself a release and does not force a version
  bump.
- Include a Breaking Changes section only for a real user upgrade, API, or
  configuration break; omit empty sections.
- Treat helper release artifacts as content-addressed. If bytes change, update
  checksums and install metadata immediately, and prefer a new version over
  replacing an existing asset in place.
- Release-asset changes affecting installation, startup, compatibility, or user
  workflow update the README and, for non-obvious tradeoffs, a postmortem.

## Pre-Commit Discipline

- Read every changed line in the full diff before committing.
- Compile and lint with zero warnings, then run the complete deterministic test
  suite, not only focused tests.
- Search for accidental private API calls, prefix violations, stale symbols,
  duplicated implementations, and temporary diagnostics before committing.
- If a fix is deliberately partial, document the deferred remainder and why;
  do not leave an unmarked heuristic shortcut.

## Postmortem Conventions

The `postmortem/` directory records design decisions and lessons learned. Read
relevant records before significant workflow, architecture, or integration
changes.

Name postmortem files with a three-digit sequence number followed by a short
slug, for example `001-helper-boundary.md`. Do not use date-prefixed filenames.

Write a postmortem when:

- adding or changing a user-visible workflow;
- choosing between non-obvious architectural approaches;
- integrating an optional dependency or external system;
- reverting or abandoning an approach, especially to document why it was wrong;
- deliberately deferring a known limitation.

Postmortems are historical records, not current product documentation. Do not
rewrite old records just to match current behavior; write a new record for the
later design and optionally add a short superseded note to the old one.

Postmortems must explain why, not restate the code. A record that only
describes what was done adds no value.
