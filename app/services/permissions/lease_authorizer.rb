module Permissions
  class LeaseAuthorizer
    class Reservation
      def initialize(lease)
        @lease = lease
        @committed = false
      end

      def commit! = @committed = true

      def release!
        return if @committed || !@lease

        PermissionLease.where(id: @lease.id).where("used_count > 0")
          .update_all("used_count = used_count - 1")
        @lease = nil
      end
    end

    Result = Data.define(:decision, :lease) do
      def authorized? = decision.allow?
    end

    def self.call(...) = new(...).call
    def self.explain(...) = new(...).explain

    # `leases:` is the owner's live (unrevoked, unexpired, uses-remaining)
    # leases, read once by a caller that explains many descriptors in a row --
    # the permission hub's matrix explains every descriptor for every subject,
    # and one query per cell made that payload over a thousand queries. Only
    # #explain reads it: #call always takes the leases it may consume under a
    # row lock.
    def initialize(descriptor:, owner:, role:, resource_scope:, rules: [], context: {}, arguments: {}, leases: nil)
      @preloaded_leases = leases
      @descriptor = descriptor
      @owner = owner
      @role = role
      @resource_scope = resource_scope
      @rules = Array(rules)
      @context = context.to_h.transform_keys(&:to_sym)
      @arguments = arguments
    end

    def call
      # An essential operation never consults (or consumes) a lease: its
      # outcome cannot depend on delegated authority.
      return Result.new(decision: evaluate([]), lease: nil) if @descriptor.essential?

      PermissionLease.transaction do
        leases = PermissionLease.for_invocation(owner: @owner, capability: @descriptor.capability,
          operation: classification.operation).lock.to_a
        decision, lease = decision_and_lease(leases)
        lease&.consume!
        Result.new(decision:, lease:)
      end
    end

    def explain
      return Result.new(decision: evaluate([]), lease: nil) if @descriptor.essential?

      decision, lease = decision_and_lease(explain_leases)
      Result.new(decision:, lease:)
    end

    private

    # The same candidates PermissionLease.for_invocation selects, filtered from
    # the preloaded set when the caller supplied one.
    def explain_leases
      operation = classification.operation
      unless @preloaded_leases
        return PermissionLease.for_invocation(owner: @owner, capability: @descriptor.capability, operation:).to_a
      end

      @preloaded_leases.select do |lease|
        lease.owner_user_id == @owner.id && lease.capability == @descriptor.capability &&
          (lease.operation.nil? || lease.operation == operation)
      end
    end

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
