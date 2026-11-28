module Workflows
  # PR's branch fell behind base; the rebase reactor wants to
  # bring it forward.
  #
  #   auto_rebase → agent_rebase → force_push
  #
  # auto_rebase tries a deterministic `git rebase` (today's
  # AutoRebase service) — non-agentic, fast, free. If it succeeds
  # cleanly, Steps::AutoRebase marks only agent_rebase `skipped`
  # and advances to force_push. If auto_rebase hits a real conflict,
  # agent_rebase runs claude with Prompts::Rebase to resolve it, then
  # force_push pushes the rebased branch.
  #
  # No summarize step — rebases don't generate a new PR title or
  # commit message; they preserve the existing branch's history.
  class Rebase < Base
    steps :auto_rebase, :agent_rebase, :force_push

    def self.trigger_kind = "rebase"

    def self.queue_name = :merges

    def self.instantiate(
      job:,
      artifacts: nil,
      agent_provider: nil,
      pr: nil,
      base_branch: nil,
      branch_name: nil,
      planned_execution_requirements: nil
    )
      super(
        job: job,
        artifacts: RebaseTarget.artifacts(
          artifacts: artifacts,
          pr: pr,
          base_branch: base_branch,
          branch_name: branch_name.presence || job.branch_name
        ),
        agent_provider: agent_provider,
        planned_execution_requirements: planned_execution_requirements
      )
    end

    # When the rebase succeeds AND the Job is still approved
    # (defer_landing preserves approval through the rebase),
    # immediately re-dispatch auto_merge so the merge happens
    # without waiting for the next LandingQueueProcessor tick.
    # LandingQueueProcessor.try_land! re-runs the standard
    # blockage / per-repository landing / approved guards, so this
    # is race-safe with the recurring loop.
    #
    # After the surrounding transaction commits: the hook runs inside the
    # rebase's success transition, holding its Workflow, and launching the
    # landing locks the new auto_merge lineage (WorkIntent, WorkUnit) below
    # it -- out of the row-lock order (NY40). Outside a transaction this runs
    # at once.
    def self.after_success(workflow)
      job = workflow.job
      return unless job&.approved?

      ActiveRecord.after_all_transactions_commit do
        LandingQueueProcessor.try_land!(job.reload)
      rescue StandardError => e
        # Best-effort like every lifecycle hook: the rebase's success is
        # committed, and the recurring landing loop picks the Job up anyway.
        Rails.logger.warn("[Workflow##{workflow.id}] after_success landing re-dispatch raised: #{e.class}: #{e.message}")
      end
    end
  end
end
