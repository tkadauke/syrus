module Workflows
  # Story 5/5A (docs/plans/delivery-tracks-and-promotion.md) `main -> develop`
  # ref-movement workflow: syncs the repository's release branch (the
  # branch direct hotfix commits land on) back into the delivery track's
  # development branch, grades the result, and publishes it per
  # `DeliveryPolicy#hotfix_sync_mode`. Not tied to any GitHub issue — the
  # anchor Job is a synthetic `direct` Job created by `HotfixSyncDispatcher`.
  # Mirrors Workflows::Promotion, direction reversed:
  #
  #   hotfix_sync_assemble → prepare → hotfix_sync_repair →
  #     retry_until(repair: hotfix_sync_repair, check: grader_fanout/grader_collect) →
  #     hotfix_sync_publish
  #
  # hotfix_sync_assemble attempts a deterministic `git merge --no-ff
  # origin/<source>` on an integration branch (`syrus/hotfix-sync-<source>-<target>-<job id>`)
  # checked out from the target branch's current tip (WorkflowWorkspace reads
  # the same `RebaseTarget` artifact keys Rebase/Promotion workflows use). A
  # clean merge skips the top-level hotfix_sync_repair occurrence entirely;
  # prepare and the grade loop run against the merged tree either way.
  #
  # hotfix_sync_repair is reused as-is for two different reasons the chain
  # can reach it: the top-level occurrence only runs after a merge conflict;
  # the retry_until loop's occurrence runs after a grade-phase failure. Both
  # invoke the repository's configured `delivery.hotfix_sync.repair_skill`.
  class HotfixSync < Base
    def self.trigger_kind = "hotfix_sync"

    def self.queue_name = :merges

    # Not the `steps(...)` class-body DSL — see Workflows::Promotion.steps_for
    # for why this is a method, not a class-body call: it reads
    # AppSetting.grade_max_iterations fresh on every instantiate call.
    def self.steps_for(_job)
      [
        "hotfix_sync_assemble", "prepare", "hotfix_sync_repair",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair_first: false,
          repair: [ :hotfix_sync_repair ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "hotfix_sync_publish"
      ]
    end

    # `artifacts` must carry `hotfix_sync_source_branch`/`hotfix_sync_target_branch`
    # (HotfixSyncDispatcher resolves these from DeliveryPolicy before calling
    # in) — this template doesn't re-resolve delivery config itself so it
    # stays a pure function of its inputs, same as Workflows::Promotion.
    def self.instantiate(job:, artifacts: nil, agent_provider: nil)
      source = artifacts.to_h["hotfix_sync_source_branch"].presence
      target = artifacts.to_h["hotfix_sync_target_branch"].presence
      raise ArgumentError, "Workflows::HotfixSync requires hotfix_sync_source_branch and hotfix_sync_target_branch artifacts" if source.blank? || target.blank?

      integration_branch = "syrus/hotfix-sync-#{source}-#{target}-#{job.id}"

      super(
        job: job,
        artifacts: RebaseTarget.artifacts(
          artifacts: artifacts,
          base_branch: target,
          branch_name: integration_branch
        ),
        agent_provider: agent_provider
      )
    end
  end
end
