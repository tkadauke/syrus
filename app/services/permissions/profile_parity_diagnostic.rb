require_dependency "permissions/permission_profiles"

module Permissions
  class ProfileParityDiagnostic
    Finding = Data.define(:profile, :role, :operation, :expected, :actual, :status) do
      def to_h = { profile:, role:, operation:, expected:, actual:, status: }
    end

    def initialize(profile:, descriptors:, role:, base_rules: [], arguments: {})
      @profile = profile
      @descriptors = Array(descriptors)
      @role = role.to_s
      @base_rules = Array(base_rules)
      @arguments = arguments
    end

    def call
      profile_rules = @profile.compile(descriptors: @descriptors, role: @role)
      @descriptors.map do |descriptor|
        expected = @profile.policy_for(descriptor, role: @role)
        actual = PolicyEvaluator.new(
          descriptor:, role: @role, resource_scope: {},
          rules: @base_rules + profile_rules, context: { role: @role }, arguments: @arguments
        ).call.policy
        Finding.new(profile: @profile.key, role: @role, operation: descriptor.operation,
          expected:, actual:, status: expected == actual ? :parity : :bounded_by_policy)
      end.freeze
    end
  end
end
