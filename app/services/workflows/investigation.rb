module Workflows
  # An investigation-only Job's chain: no PR is expected. Launched from a
  # `direct` Job flagged `investigation: true` (see Job#investigation_launch?,
  # InvestigationJobs::Creator) instead of a free-form implementation prompt.
  #
  #   prepare → investigate → submit_report
  #
  # Unlike Workflows::Skill, a blank diff is not a failure here at all --
  # `investigate` never captures or requires a diff (it is read-only, the
  # same as AgentInsights::RunStep). Success is defined by `submit_report`
  # persisting a narrative report artifact, so the chain always reaches a
  # narrative-producing step instead of dead-ending in the generic
  # no_changes closure.
  #
  # Unlike AgentInsights::Workflow, this chain does NOT end in `auto_close`:
  # investigation Jobs are operator-facing, not infrastructure, so a
  # submitted report should land the Job in :implemented -- the same
  # "done, awaiting operator review" state a PR-based Job reaches after
  # `pr_open` -- rather than closing itself the instant the report is
  # submitted. This trigger kind does not set owns_job_lifecycle, so the
  # ordinary Workflows::JobLifecyclePropagation success/failure propagation
  # applies: success carries the Job from :running to :implemented, and a
  # failed investigate/submit_report step leaves the Job for the normal
  # Retry path. The operator (or a chat close_job_successfully tool call)
  # then closes the Job with closure_reason: "investigation_reported" once
  # they've reviewed the report.
  class Investigation < Base
    def self.trigger_kind = "investigation"

    def self.steps_for(job)
      prepare_then(job, "investigate", "submit_report")
    end
  end
end
