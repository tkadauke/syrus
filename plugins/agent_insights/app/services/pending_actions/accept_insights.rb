module PendingActions
  class AcceptInsights < Base
    action_key "accept_insights"

    def execute = mutation.apply!.then { action }
    def authorize_execution! = mutation.validate.then { |result| raise ArgumentError, result.message unless result.ok? }
    def validate_payload(errors)
      errors.add(:payload, "insight_ids are required") if payload["insight_ids"].blank?
    end
    def presentation_label = "Accept #{payload.fetch('insight_ids').size} insights"
    def presentation_detail = "#{insight_detail} · #{payload.fetch('proposal_types', {}).values.join(', ')}"

    private

    def mutation = @mutation ||= AgentInsights::Mutations::Accept.new(ids: payload.fetch("insight_ids"), actor: user, repository_scope: permitted_repositories)
    def permitted_repositories = user.admin? ? Repository.all : Repository.accessible_to(user)
    def insight_detail = "Insights #{payload.fetch('insight_ids').map { |id| "##{id}" }.join(', ')}"
  end
end
