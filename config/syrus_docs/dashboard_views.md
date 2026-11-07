# Dashboard Views

Jobs and Epics dashboards support **list**, **kanban**, and **dependencies**
views. List is the compact operational view, kanban groups by lifecycle state,
and dependencies shows a topological graph of blocking relationships. The
dependencies view is desktop-only.

The Inbox includes work actionable by the current user, including Jobs where
the user is an eligible approver. Proposed direct Jobs can be reviewed and
routed before confirmation. Backlogged Jobs may be released, reprioritized,
assigned, tagged, claimed, or returned to triage through their available
actions.

Queued cards show why execution has not started, including unfinished or
failed dependencies, main-branch health, active higher-priority work, linear
Epic sibling execution, provider availability, placement, and workflow
admission. Manual pause lets the active Step finish and then stops before the
next Run; only an explicit unpause clears it.

A Job can remain `running` while its WorkUnit is blocked and no Run executes.
These Jobs appear in **Blocked**, not **In progress** or **Paused**, and Job
detail shows the reason and recheck time. Provider-availability pauses are
automatic and reversible; operators can recheck or resume anyway. Provider
routing applies ordered Job, repository, then user rules. The rules editor's
**Test** button dry-runs the effective rules, and `explain_provider_routing`
returns the same explanation.

Bulk management applies actions per selected Job and reports skipped items.
Bulk retry chooses the narrowest safe recovery path rather than always starting
a new implementation Workflow. Explicit **Retry implementation** remains on
Job detail when an operator intentionally wants a full retry.

The dependencies graph accepts the same effective dashboard filter and lets an
operator navigate from nodes to Job or Epic detail. All searchable/filterable
dashboard views use the shared FilterBar behavior and SmartFolder persistence.

Frontend composition, folder-exclusion invariants, payloads, and the developer
FilterBar/SmartFolder contract live in [dashboard-view
architecture](../../docs/engineering/architecture/dashboard-views.md).
