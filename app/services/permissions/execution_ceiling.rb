module Permissions
  # Limits applied after policy evaluation. A ceiling can only lower a decision
  # (allow -> ask -> deny); nothing here, and no rule or lease, can raise one.
  # That keeps container confinement, network profiles, and the tool limits of
  # an agent provider authoritative: an operator allow rule never widens them.
  class ExecutionCeiling
    RANK = PolicyEvaluator::POLICY_RANK

    Applied = Data.define(:source, :policy, :reason) do
      def to_h = { source:, policy:, reason: }
    end

    # Each limit answers with the policy it caps the invocation at, or nil.
    class Limit
      def initialize(source:, reason:) = (@source = source; @reason = reason)
      attr_reader :source, :reason
      def cap(_effects, _subject) = nil
    end

    # Egress that the network profile forbids is denied outright.
    class NetworkProfile < Limit
      def initialize = super(source: :confinement, reason: :network_profile_forbids_egress)
      def cap(effects, subject) = (:deny if effects.include?(:network_read) && subject.network.to_s == "grader")
    end

    # A fail-closed workload must not escalate to the host, whatever a rule says.
    class FailClosedHost < Limit
      def initialize = super(source: :confinement, reason: :host_execution_forbidden_by_workload_policy)
      def cap(_effects, subject) = (:deny if subject.location == :host && subject.container_backend == :required)
    end

    # Provider-declared limits: effect => policy the provider's native tool
    # surface may never exceed, e.g. { privilege_change: :deny }.
    class ProviderLimits < Limit
      def initialize(limits)
        super(source: :provider, reason: :provider_ceiling)
        @limits = limits.to_h.transform_keys(&:to_sym).transform_values(&:to_sym)
      end

      def cap(effects, subject)
        return unless subject.location == :provider_native

        @limits.values_at(*effects).compact.min_by { |policy| RANK.fetch(policy) }
      end
    end

    def self.default = new([ NetworkProfile.new, FailClosedHost.new ])

    def initialize(limits = [])
      @limits = limits
    end

    def with(*limits) = self.class.new(@limits + limits)

    # Returns [final_policy, [Applied...]]
    def apply(policy, effects:, subject:)
      applied = []
      @limits.each do |limit|
        cap = limit.cap(effects, subject)
        next unless cap && RANK.fetch(cap) < RANK.fetch(policy)

        policy = cap
        applied << Applied.new(source: limit.source, policy: cap, reason: limit.reason)
      end
      [ policy, applied ]
    end
  end
end
