# Handled frontend errors

Frontend code that catches an unexpected failure and preserves a local recovery
flow must call `reportHandledError`. Supply stable, content-free `surface`,
`operation`, and `stage` names; the shared reporter owns privacy scrubbing,
fingerprinting, correlation, and duplicate suppression. Diagnostics are limited
to its allowlist. Do not construct browser-error payloads in product surfaces.

React Query and the API layer report terminal request failures centrally. A
surface catch should keep its local notice or fallback but must not report the
same API error again unless it represents a distinct local stage after the
request, such as decoding or rendering the response.

Cancellation, polling state, validation, authorization prompts, and declined
user actions are control flow rather than failures. When a catch exists only to
implement one of those outcomes, add a concise `handled-error-expected` comment
inside its body explaining the case.

`design-system/no-swallowed-errors` enforces this contract. Its per-file counts
in `eslint-rules/baseline.json` are the migration inventory for legacy catches:
new files start at zero, existing files may not exceed their recorded count,
and each migration should regenerate or reduce the relevant entry. The
`design-system/no-direct-browser-error-payload` rule separately reserves raw
payload construction for the shared reporter and error-boundary infrastructure.
