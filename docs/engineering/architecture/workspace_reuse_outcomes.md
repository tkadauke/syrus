# Workspace reuse outcomes

Syrus durably records prepare and distributed-grader workspace decisions in
`workspace_reuse_outcomes`. Each row identifies the repository, Workflow,
Step, Run, execution backend, timestamp, and prepare fingerprint. Prepare rows
record whether work was rebuilt, skipped, or restored from reusable prepared
state. Grader fan-out rows record the materialization method (`overlay`,
`hardlink`, or `copy`), fallback reason, grader count, and elapsed time. Byte
counts are populated only when the materializer knows them without an extra
filesystem scan.

The generic Retention Settings registry controls these rows through the
`workspace_reuse_outcome` policy. Its default retention is 90 days, long enough
for multi-week comparisons without adding an AppSetting column.

## Read-only analysis

Syrus-repository implementation and investigation agents can call the
read-only `read_workspace_reuse_outcomes` MCP tool with optional inclusive
ISO 8601 `since` and `until_time` bounds. The tool defaults to the last 30
days and scopes results to the current repository.

The underlying query service remains available from a Rails console:

```ruby
WorkspaceReuseOutcomes::Summary.call(
  since: 30.days.ago,
  until_time: Time.current,
  repository: Repository.find_by!(owner: "example", name: "project")
)
```

The result is grouped by repository, prepare fingerprint, backend, and event
kind. Each entry includes outcome counts, a total, and (for prepare entries) a
`reuse_rate`. Skipped preparations are reported in the total but excluded from
the reuse-rate denominator because no reusable layer was requested. The query
does not mutate cache or workflow state.
