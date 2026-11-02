module Permissions
  class RequestPresenter
    def initialize(request, current_user: nil)
      @request = request
      @current_user = current_user
    end

    def as_json
      {
        id: request.id, state: request.state,
        actionable: request.user_id == @current_user&.id && request.actionable? && request.pending?,
        purpose: request.purpose, requested_by: request.requested_by,
        runtime_role: request.runtime_role, created_at: request.created_at,
        checkpoint_state: request.checkpoint_state,
        non_actionable_reason: request.non_actionable_reason,
        origin: reference(request.origin), subject: reference(request.subject),
        repository: reference(request.repository),
        items: request.authorization_items.map { |item| item_json(item) }
      }
    end

    private

    attr_reader :request

    def item_json(item)
      {
        id: item.id, kind: item.kind, state: item.state,
        capability: item.capability, operation: item.operation,
        resource_type: item.resource_type,
        resource_scope: ToolPayloadRedactor.redact(item.resource_scope),
        arguments: ToolPayloadRedactor.redact(item.normalized_arguments),
        effects: item.effects, risk: item.risk, purpose: item.purpose,
        policy_chain: item.policy_chain, decisive_rule: item.decisive_rule,
        requested_durations: item.requested_durations,
        selected_duration: item.selected_duration,
        decision_reason: item.decision_reason, decided_at: item.decided_at
      }
    end

    def reference(record)
      return nil unless record

      label = if record.respond_to?(:slug) && record.slug.present?
        record.slug
      elsif record.respond_to?(:name) && record.name.present?
        record.name
      elsif record.respond_to?(:title) && record.title.present?
        record.title
      else
        "#{record.class.base_class.model_name.human} ##{record.id}"
      end
      { type: record.class.base_class.name, id: record.id, label: }
    end
  end
end
