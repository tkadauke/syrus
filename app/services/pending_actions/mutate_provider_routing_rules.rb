module PendingActions
  class MutateProviderRoutingRules < Base
    action_key "mutate_provider_routing_rules"

    def authorize_execution!
      rule_set
    end

    def execute
      progress!("Applying provider-routing rule changes...")
      rule_set.mutate!(operations: payload.fetch("operations"), expected_revision: payload.fetch("expected_revision"))
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "scope is required") unless payload["scope"].is_a?(Hash)
      errors.add(:payload, "expected_revision is required") if payload["expected_revision"].blank?
      errors.add(:payload, "operations are required") unless payload["operations"].is_a?(Array) && payload["operations"].any?
    end

    def presentation_label
      "Update provider routing rules"
    end

    def presentation_detail
      summary = payload["summary"].presence
      heading = [ scope_label, summary ].compact.join(": ")
      "#{heading}\nBefore: #{format_rules(payload.dig('before', 'rules'))}\nAfter: #{format_rules(payload.dig('after', 'rules'))}"
    end

    private

    def rule_set
      scope = payload.fetch("scope").symbolize_keys
      authorize_scope!(scope)
      ProviderRouting::RuleSet.new(**scope)
    end

    def authorize_scope!(scope)
      case scope.fetch(:scope_type)
      when "user"
        raise ArgumentError, "User scope is no longer accessible." unless scope.fetch(:scope_id).to_i == user.id
      when "repository"
        target = Repository.active.find(scope.fetch(:scope_id))
        raise ArgumentError, "Repository scope is no longer accessible." unless RepositoryPolicy.new(user, target).update?
      when "job"
        target = Job.find(scope.fetch(:scope_id))
        raise ArgumentError, "Job scope is no longer accessible." unless JobPolicy.new(user, target).write?
      else
        raise ArgumentError, "Unknown provider-routing scope."
      end
    end

    def scope_label
      scope = payload["scope"]
      return "Provider routing rules" unless scope.is_a?(Hash) && scope["scope_type"].present? && scope["scope_id"].present?

      "#{scope['scope_type'].humanize} ##{scope['scope_id']}"
    end

    def format_rules(rules)
      Array(rules).map do |rule|
        rule = rule.to_h.deep_stringify_keys
        state = rule["enabled"] ? "enabled" : "disabled"
        [
          "#{rule['position']}. #{state}",
          "task=#{rule['task_key']}",
          "trigger=#{JSON.generate(rule['trigger'] || {})}",
          "conditions=#{JSON.generate(rule['conditions'] || {})}",
          "action=#{JSON.generate(rule['action'] || {})}"
        ].join(" | ")
      end.join("\n").presence || "no rules"
    end
  end
end
