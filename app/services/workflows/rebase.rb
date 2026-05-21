module Workflows
  # PR's branch fell behind base; the rebase reactor wants to
  # bring it forward.
  #
  #   auto_rebase → agent_rebase → force_push
  #
  # auto_rebase tries a deterministic `git rebase` (today's
  # AutoRebase service) — non-agentic, fast, free. If it succeeds
  # cleanly, Steps::AutoRebase marks only agent_rebase `cancelled`
  # and advances to force_push. If auto_rebase hits a real conflict,
  # agent_rebase runs claude with Prompts::Rebase to resolve it, then
  # force_push pushes the rebased branch.
  #
  # No summarize step — rebases don't generate a new PR title or
  # commit message; they preserve the existing branch's history.
  class Rebase < Base
    steps :auto_rebase, :agent_rebase, :force_push

    def self.trigger_kind = "rebase"

    # When the rebase succeeds AND the Job is still approved
    # (defer_landing preserves approval through the rebase),
    # immediately re-dispatch auto_merge so the merge happens
    # without waiting for the next LandingQueueProcessor tick.
    # LandingQueueProcessor.try_land! re-runs the standard
    # blockage / per-repository landing / approved guards, so this
    # is race-safe with the recurring loop.
    def self.after_success(workflow)
      return unless workflow.job&.approved?

      LandingQueueProcessor.try_land!(workflow.job)
    end
  end
end
