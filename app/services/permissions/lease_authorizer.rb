module Permissions
  class LeaseAuthorizer
    Result = Data.define(:decision, :lease) do
      def authorized? = decision.allow?
    end

    def self.call(...) = new(...).call
    def self.explain(...) = new(...).explain

    def initialize(descriptor:, owner:, role:, resource_scope:, rules: [], context: {}, arguments: {})
      @descriptor = descriptor
      @owner = owner
      @role = role
      @resource_scope = resource_scope
      @rules = Array(rules)
      @context = context.to_h.transform_keys(&:to_sym)
      @arguments = arguments
    end

    def call
      PermissionLease.transaction do
        leases = PermissionLease.for_invocation(owner: @owner, capability: @descriptor.capability,
          operation: classification.operation).lock.to_a
        decision, lease = decision_and_lease(leases)
        lease&.consume!
        Result.new(decision:, lease:)
      end
    end

    def explain
      leases = PermissionLease.for_invocation(owner: @owner, capability: @descriptor.capability,
        operation: classification.operation).to_a
      decision, lease = decision_and_lease(leases)
      Result.new(decision:, lease:)
    end

    private

    def classification
      @classification ||= InvocationClassifier.call(descriptor: @descriptor, arguments: @arguments)
    end

    def decision_and_lease(leases)
      fingerprint = InvocationFingerprint.call(descriptor: @descriptor, arguments: @arguments)
      normalized_arguments = @descriptor.normalize_fingerprint(@arguments)
      available = leases.select do |lease|
        lease.available?(context: @context, fingerprint:, effects: classification.effects,
          arguments: normalized_arguments)
      end
      decision = evaluate(available)
      lease = available.find { |item| decision.decisive_rule&.id == item.to_policy_rule.id }
      [ decision, lease ]
    end

    def evaluate(leases)
      PolicyEvaluator.new(descriptor: @descriptor, role: @role, resource_scope: @resource_scope,
        rules: @rules + leases.map(&:to_policy_rule), context: @context, arguments: @arguments).call
    end
  end
end
