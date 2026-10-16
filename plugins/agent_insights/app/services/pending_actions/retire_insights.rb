module PendingActions
  class RetireInsights < Base
    action_key "retire_insights"

    def execute = mutation.apply!.then { action }
    def authorize_execution! = mutation.validate.then { |result| raise ArgumentError, result.message unless result.ok? }
    def validate_payload(errors)
      errors.add(:payload, "insight_ids are required") if payload["insight_ids"].blank?
      errors.add(:payload, "reason is required") if payload["reason"].blank?
    end
    def presentation_label = "Retire #{payload.fetch('insight_ids').size} insights"
    def presentation_detail = "Insights #{payload.fetch('insight_ids').map { |id| "##{id}" }.join(', ')} · #{payload.fetch('proposal_types', {}).values.join(', ')} · #{payload['reason']}"

    private

    def mutation
      @mutation ||= AgentInsights::Mutations::Retire.new(ids: payload.fetch("insight_ids"), actor: user,
        repository_scope: permitted_repositories, reason: payload["reason"], retire_accepted: payload["retire_accepted"],
        superseded_by_insight_ids: payload["superseded_by_insight_ids"], superseded_by_job_ids: payload["superseded_by_job_ids"])
    end
    def permitted_repositories = user.admin? ? Repository.all : Repository.accessible_to(user)
  end
end
