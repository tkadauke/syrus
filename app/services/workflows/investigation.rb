module Workflows
  # An investigation-only Job's chain: no PR is expected. Launched from a
  # `direct` Job flagged `investigation: true` (see Job#investigation_launch?,
  # InvestigationJobs::Creator) instead of a free-form implementation prompt.
  #
  #   prepare → investigate → submit_report → auto_close
  #
  # Unlike Workflows::Skill, a blank diff is not a failure here at all --
  # `investigate` never captures or requires a diff (it is read-only, the
  # same as AgentInsights::RunStep). Success is defined by `submit_report`
  # persisting a narrative report artifact, so the chain always reaches a
  # narrative-producing step instead of dead-ending in the generic
  # no_changes closure. `auto_close` then closes the Job as part of normal
  # step progression, mirroring AgentInsights::Workflow's shape -- but
  # because that only happens on success, a failed investigate/submit_report
  # step still leaves the Job for the normal Retry path (this trigger kind
  # does not set owns_job_lifecycle, so ordinary Workflows::JobLifecyclePropagation
  # failure handling applies).
  class Investigation < Base
    def self.trigger_kind = "investigation"

    def self.steps_for(job)
      prepare_then(job, "investigate", "submit_report", "auto_close")
    end
  end
end
