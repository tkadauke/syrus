module RefMovementActions
  # Manually promotes the configured development branch into the release
  # branch using the existing promotion workflow. Promotion configuration is
  # the action's policy source; repositories do not need to duplicate it under
  # `delivery.ref_movement_actions`.
  class PromoteDevelopmentToRelease < Base
    ACTION_NAME = "promote_development_to_release"

    def dispatch!(repository:, actor:, action:, source: nil, target: nil)
      policy = DeliveryPolicy.for(repository: repository)
      source_branch = source.presence || policy.promotion_source_branch
      target_branch = target.presence || policy.promotion_target_branch
      available, reason = available?(repository: repository)

      attributes = {
        repository: repository,
        requested_by_user: actor,
        action_name: action,
        mode: policy.promotion_mode,
        grade_phases: policy.promotion_grade_phases,
        source_kind: "branch",
        source_ref: source_branch,
        target_kind: "release_branch",
        target_ref: target_branch,
        target_repository: repository,
        target_inferred: target.blank?
      }

      unless available
        return RefMovementAction.create!(attributes.merge(state: "blocked", blocked_reason: reason))
      end

      workflow = PromotionDispatcher.call!(
        repository: repository,
        user: actor,
        source_branch: source_branch,
        target_branch: target_branch
      )

      RefMovementAction.create!(attributes.merge(state: "dispatched", job: workflow.job, workflow: workflow))
    end

    def available?(repository:, job: nil, source_branch: nil)
      policy = DeliveryPolicy.for(repository: repository)
      return [ false, "promotion is not enabled" ] unless policy.promotion_enabled?

      workflow = pending_workflow(repository)
      return [ false, "promotion workflow #{workflow.id} is already #{workflow.state}" ] if workflow

      [ true, nil ]
    end

    private

    def pending_workflow(repository)
      Workflow.joins(:job)
        .where(trigger_kind: "promotion", state: %w[queued running], jobs: { repository_id: repository.id })
        .order(:id)
        .first
    end
  end
end
