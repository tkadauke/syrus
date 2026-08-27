module Workflows
  # Story 2 (docs/plans/delivery-tracks-and-promotion.md) `develop -> main`
  # ref-movement workflow: assembles the delivery track's source branch into
  # the target branch, grades the result, and publishes it per
  # `DeliveryPolicy#promotion_mode`. Not tied to any GitHub issue — the
  # anchor Job is a synthetic `direct` Job created by `PromotionDispatcher`.
  #
  #   promotion_assemble → prepare → promotion_repair →
  #     retry_until(repair: promotion_repair, check: grader_fanout/grader_collect) →
  #     promotion_publish
  #
  # promotion_assemble attempts a deterministic `git merge --no-ff
  # origin/<source>` on an integration branch checked out from the target
  # branch's tip (WorkflowWorkspace reads the same `RebaseTarget` artifact
  # keys Rebase workflows use — see .instantiate below). A clean merge skips
  # the top-level promotion_repair occurrence entirely (no conflict to
  # resolve); prepare and the grade loop run against the merged tree either
  # way.
  #
  # promotion_repair is reused as-is for two different reasons the chain can
  # reach it: the top-level occurrence only runs after a merge conflict;
  # the retry_until loop's occurrence runs after a `promotion` grade-phase
  # failure. Both invoke the repository's configured
  # `delivery.promotion.repair_skill` — "resolve whatever's broken right
  # now" is the same contract either way.
  class Promotion < Base
    def self.trigger_kind = "promotion"

    def self.queue_name = :merges

    # Not the `steps(...)` class-body DSL: that would evaluate
    # AppSetting.grade_max_iterations once at class-load time and bake a
    # stale limit into every future instantiate call. steps_for is called
    # fresh from .instantiate below, so it reads the current setting every
    # time — same reason Workflows::AutoMerge builds its chain from
    # landing_grader_retry_loop inside steps_for rather than the DSL.
    def self.steps_for(_job)
      [
        "promotion_assemble", "prepare", "promotion_repair",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair_first: false,
          repair: [ :promotion_repair ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "promotion_publish"
      ]
    end

    # `artifacts` must carry `promotion_source_branch`/`promotion_target_branch`
    # (PromotionDispatcher resolves these from DeliveryPolicy before calling
    # in) — this template doesn't re-resolve delivery config itself so it
    # stays a pure function of its inputs, the same way Rebase takes an
    # already-resolved base_branch/branch_name rather than reaching into
    # DeliveryPolicy on its own.
    def self.instantiate(job:, artifacts: nil, agent_provider: nil)
      source = artifacts.to_h["promotion_source_branch"].presence
      target = artifacts.to_h["promotion_target_branch"].presence
      raise ArgumentError, "Workflows::Promotion requires promotion_source_branch and promotion_target_branch artifacts" if source.blank? || target.blank?

      integration_branch = "syrus/promote-#{source}-#{target}-#{job.id}"

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
