module Permissions
  class PermissionPreset
    NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/
    REQUIRED_RULE_KEYS = %i[capability operation role policy resource_scope constraints].freeze

    attr_reader :name, :label, :description

    def initialize(name:, label:, description:, rules:)
      @name = name.to_s
      @label = label.to_s
      @description = description.to_s
      @rules = rules
      validate_declaration!
      freeze
    end

    def render(context = {})
      context = context.to_h.with_indifferent_access
      Array(@rules.respond_to?(:call) ? @rules.call(context) : @rules).map do |rule|
        render_rule(rule, context)
      end.freeze
    end

    def contract_key
      [ name, label, description, @rules.respond_to?(:call) ? @rules : render ]
    end

    private

    def validate_declaration!
      raise ArgumentError, "permission preset name must be a stable lowercase identifier" unless name.match?(NAME_PATTERN)
      raise ArgumentError, "permission preset label must be present" if label.blank?
      raise ArgumentError, "permission preset description must be present" if description.blank?
      raise ArgumentError, "permission preset rules must be an array or callable" unless @rules.is_a?(Array) || @rules.respond_to?(:call)
      raise ArgumentError, "permission preset must contain at least one rule" if @rules.is_a?(Array) && @rules.empty?

      render(subject_selector_type: "role") if @rules.is_a?(Array)
    end

    def render_rule(rule, context)
      draft = rule.to_h.with_indifferent_access
      missing = REQUIRED_RULE_KEYS.reject { |key| draft.key?(key) }
      raise ArgumentError, "permission preset rule is missing: #{missing.join(', ')}" if missing.any?

      policy = draft.fetch(:policy).to_sym
      raise ArgumentError, "unknown permission preset policy: #{policy}" unless CapabilityDescriptor::POLICIES.include?(policy)

      subject = context.slice(:subject_selector_type, :subject_selector_id, :subject_repository_id)
      raise ArgumentError, "permission preset requires subject_selector_type" if subject[:subject_selector_type].blank?

      draft.merge(subject).merge(
        capability: draft.fetch(:capability).to_s,
        operation: draft.fetch(:operation).to_s,
        role: draft.fetch(:role).to_s,
        policy: policy.to_s,
        resource_scope: draft.fetch(:resource_scope).to_h,
        constraints: draft.fetch(:constraints).to_h
      ).stringify_keys.freeze
    end
  end
end
