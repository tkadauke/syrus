require_dependency "permissions/policy_rule"
require_dependency "permissions/tool_set_bundles"
require_dependency "permissions/coworker_default_policy"

module Permissions
  class PermissionProfile
    IDENTIFIER_PATTERN = ToolSetBundle::IDENTIFIER_PATTERN
    attr_reader :key, :label, :description

    def initialize(key:, label:, description:, &policy)
      @key = key.to_s.freeze
      @label = label.to_s.freeze
      @description = description.to_s.freeze
      @policy = policy
      raise ArgumentError, "permission profile key must be versioned" unless @key.match?(IDENTIFIER_PATTERN)
      raise ArgumentError, "permission profile requires a policy" unless @policy.respond_to?(:call)
      freeze
    end

    def policy_for(descriptor, role:)
      role = role.to_s
      return :deny unless descriptor.requestable_roles.include?(role)
      return descriptor.defaults.fetch(role, :deny) if descriptor.maximum_autonomy == :none

      @policy.call(descriptor, role).to_sym
    end

    # Profiles compile to the same role-layer rules consumed by PolicyEvaluator.
    # Resource/provider ceilings and narrower rules therefore remain authoritative.
    def compile(descriptors:, role:)
      Array(descriptors).uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }.map do |descriptor|
        PolicyRule.new(
          id: "profile:#{key}:#{role}:#{descriptor.operation}",
          layer: :role,
          policy: policy_for(descriptor, role:),
          source: "permission_profile:#{key}",
          capability: descriptor.capability,
          operation: descriptor.operation,
          selectors: { role: role.to_s },
          rationale: "#{label} profile via #{descriptor.tool_set_bundle}"
        )
      end.freeze
    end

    def to_h = { key:, label:, description: }

    class << self
      def safe_local?(descriptor)
        descriptor.effects.present? && CoworkerDefaultPolicy.auto_allowable?(
          effects: descriptor.effects, risk: descriptor.risk, benign_internal: descriptor.benign_internal
        )
      end
    end
  end
end
