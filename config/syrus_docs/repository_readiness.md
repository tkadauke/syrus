# Repository readiness

Syrus can inspect repository readiness without executing repository code. The
first-run checklist and Repository Overview show a compact status that opens a
full report.

The report validates `.syrus.yml`, language versions, manifests, lockfiles,
resolved prepare and grader commands, capability requirements, queues, and
live-worker compatibility. Mutable implementation workspaces and independently
scheduled targets are evaluated separately.

Results are **Ready**, **Ready with warnings**, **Needs configuration**, or
**Incompatible**. Environment heuristics are warnings. Hard blocks are limited
to invalid configuration, unavailable repository content or credentials, and
the absence of a live worker satisfying explicit capabilities.

Operators may start one disposable execution probe per repository. It checks
out the default branch, installs declared toolchains, runs prepare, and runs at
most one grader under time limits. The report shows durations, disk growth,
bounded output, missing executables, and cleanup status. Concurrent requests
reuse the active probe; retries start a fresh one.

An explicitly required command that cannot start blocks the first initial
implementation workflow. An operator can acknowledge and override that warning
from either readiness surface, after which the queued workflow is reconsidered
without creating another Job or branch.
