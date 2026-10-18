# Repository readiness

The first-run onboarding page statically inspects the first active repository
after it is selected. Opening or refreshing the report never clones the
repository and never executes its code.

The report resolves the configured default branch through `RepositoryContent`,
validates `.syrus.yml`, inspects language-version files, package manifests and
lockfiles, and uses the same prepare, grader, capability, and queue-resolution
logic as execution. It shows the exact proposed prepare and grader commands.
Worker compatibility is evaluated separately for the workflow workspace and
for each executable target or grader, because independently scheduled scopes
may run on different workers. The report lists each scope's command,
capabilities, queue, and live-worker result.

Results are **Ready**, **Ready with warnings**, **Needs configuration**, or
**Incompatible**. Heuristic environment and system-package findings are
warnings. Hard blocks are limited to invalid configuration, unavailable or
inaccessible repository content (including missing credentials), and no live
worker satisfying explicitly required capabilities.

Operators can explicitly start a **disposable execution probe** from this
report. The probe is its own persisted lifecycle record, not a Job, Workflow,
Step, or Run. A worker shallow-clones the default branch into
`$SYRUS_DATA_ROOT/execution-probes/<probe-id>`, scrubs the authenticated remote,
runs `mise install` when version declarations are present, runs the resolved
prepare commands, and then runs at most one configured grader (or one detected
grader candidate). Each command is time-bounded. The result records durations,
checkout and final byte counts, disk growth, bounded output tails, missing
executables, and cleanup state. The checkout is removed in an `ensure` path on
success and failure; retrying creates a new record and checkout.
The onboarding report polls while a probe is queued or running and stops after
the first terminal result. A database single-flight constraint permits only
one queued/running probe per repository, so concurrent clicks or requests
reuse the same probe instead of launching duplicate dependency installs.

Toolchain failures are reported separately and prominently. If an explicitly
required prepare or grader command exits because it cannot be started, the
latest probe blocks the repository's first initial implementation workflow.
An operator can acknowledge and override that warning from onboarding; the
queued workflow is then reconsidered without creating another Job or branch.
