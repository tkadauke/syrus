# Repository readiness

The first-run onboarding page statically inspects the first active repository
after it is selected. The report stays outside Jobs, Workflows, Steps, and Runs:
opening or refreshing it never clones the repository and never executes its
code.

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
