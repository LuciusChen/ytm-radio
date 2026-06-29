# Explicit Helper Errors

## Context

The helper exposed structured error fields, but generated them by searching
human-readable error strings for phrases such as HTTP status text, connection
failures, or browser restart diagnostics. Changing diagnostic wording could
silently change `code`, `retryable`, or `auth-required` and make Emacs choose the
wrong recovery path.

Top-level help was another protocol exception: it wrote unversioned prose to
stdout even though helper stdout otherwise used JSON envelopes.

## Decision

The Rust helper uses an explicit error type carrying code, message,
retryability, and authentication state. Authentication, browser restart,
network, remote response, invalid request, and generic helper failures assign
their metadata where the error originates. Wrapping an error with context
preserves that metadata.

Help is represented as a normal successful command whose usage text is stored
inside the versioned response data.

## Consequences

Diagnostic wording can evolve without changing Emacs recovery behavior. All
normal command paths keep stdout machine-readable, including help and errors.
New failure sites must choose an explicit error category or deliberately use
the generic helper-failure category.
