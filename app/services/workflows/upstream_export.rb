module Workflows
  # Story 8/9 (docs/plans/delivery-tracks-and-promotion.md) per-job
  # upstream-export workflow: open/update a PR from an already-approved Job's
  # own branch to the canonical repository's intake branch.
  #
  #   upstream_export_publish
  #
  # Unlike Promotion/HotfixSync, there is no ref to assemble and nothing to
  # grade here — the Job's branch already passed its own grade loop as part
  # of the Initial/Retry workflow that got it approved. This is a single
  # non-agentic publish step, dispatched directly onto the existing dev Job
  # (see UpstreamExportDispatcher) rather than a synthetic anchor Job.
  class UpstreamExport < Base
    steps :upstream_export_publish

    def self.trigger_kind = "upstream_export"

    def self.queue_name = :merges
  end
end
