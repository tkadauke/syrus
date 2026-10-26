module RefMovementActions
  class PromoteDevelopmentToRelease < Base
    def dispatch!(repository:, actor:, action:, source: nil, target: nil)
      policy = DeliveryPolicy.for(repository: repository)
      source_branch = source.presence || policy.promotion_source_branch
      target_branch = target.presence || policy.promotion_target_branch
      available, reason = available?(repository: repository)

      attributes = if available
        workflow = PromotionDispatcher.call!(
          repository: repository,
          user: actor,
          source_branch: source_branch,
          target_branch: target_branch
        )
        {
          state: "dispatched", source_kind: "branch", source_ref: source_branch,
          target_kind: "branch", target_ref: target_branch, target_inferred: target.blank?,
          job: workflow.job, workflow: workflow
        }
      else
        { state: "blocked", blocked_reason: reason, source_ref: source_branch, target_ref: target_branch }
      end

      RefMovementAction.create!(
        { repository: repository, requested_by_user: actor, action_name: action, mode: policy.promotion_mode, grade_phases: [ "promotion" ] }.merge(attributes)
      )
    end

    def available?(repository:, job: nil, source_branch: nil)
      policy = DeliveryPolicy.for(repository: repository)
      return [ false, "promotion is not enabled" ] unless policy.promotion_enabled?

      workflow = Workflow.joins(:job)
        .where(trigger_kind: "promotion", state: %w[queued running], jobs: { repository_id: repository.id })
        .order(:id).first
      return [ false, "promotion workflow #{workflow.id} is already #{workflow.state}" ] if workflow

      [ true, nil ]
    end
  end
end
