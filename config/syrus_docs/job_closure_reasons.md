# Job closure reasons

Every closed Job records a registered reason and provenance. The current Job shows the reason, optional note and Job/PR/Epic references, actor, and path used to close it; reopening clears the current closure fields while retaining state-transition history.

Reasons are grouped as delivered (`pr_merged`, `external_pr_merged`, `emergency_landed`, `hotfix_sync_landed`, `investigation_reported`, `already_implemented`, `implemented_elsewhere`, `not_needed`), replaced (`superseded`, `duplicate`, `merged_into`, `split`), declined (`obsolete`, `wont_do`, `out_of_scope`, `infeasible`), gave up (`too_many_failures`, `too_many_workflows`, `repair_exhausted`), external (`issue_closed`, `pr_closed`, `external_pr_closed`, `epic_archived`, `repository_archived`), bookkeeping, and human cancellation.

Agents close through `close_job_successfully` and must always provide a registered reason. Reasons that require references or notes reject incomplete calls. Declined outcomes require operator confirmation. `cancelled` is reserved for a human who uses the existing close flow without choosing a reason. Plugins register their bookkeeping reasons alongside their workflow kinds.
