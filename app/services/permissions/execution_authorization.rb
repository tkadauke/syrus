module Permissions
  # Decides whether a host, container, or provider-native effect may proceed.
  #
  # Rules come from the caller (the owner's durable rules) and are evaluated by
  # +PolicyEvaluator+ like every other capability. Two further limits apply:
  #
  # 1. Sensitive effects (credential use, privilege change, destructive or
  #    external writes) that were only allowed by the descriptor default, not by
  #    an explicit rule, are lowered to +ask+.
  # 2. +ExecutionCeiling+ limits (confinement, network profile, provider
  #    ceilings) then lower the result further. They can never raise it.
  class ExecutionAuthorization
    Result = Data.define(:decision, :policy, :ceilings, :subject) do
      def allowed? = policy == :allow
      def ask? = policy == :ask
      def denied? = policy == :deny
      def to_h = { policy:, ceilings: ceilings.map(&:to_h), decision: decision.to_h }
    end

    def self.authorize(...) = new(...).authorize

    def initialize(subject:, role:, rules: [], ceiling: ExecutionCeiling.default, context: {})
      @subject = subject
      @role = role.to_s
      @rules = rules
      @ceiling = ceiling
      @context = context
    end

    def authorize
      descriptor = ExecutionActions.descriptor_for(@subject.location)
      decision = PolicyEvaluator.new(
        descriptor:, role: @role, resource_scope: {}, rules: @rules, context: @context,
        arguments: ExecutionActions.arguments_for(@subject)
      ).call
      effects = decision.invocation.effects
      policy = decision.policy

      if policy == :allow && decision.decisive_rule.nil? && (effects & ExecutionActions::SENSITIVE_EFFECTS).any?
        policy = :ask
      end

      policy, applied = @ceiling.apply(policy, effects:, subject: @subject)
      Result.new(decision:, policy:, ceilings: applied, subject: @subject)
    end
  end
end
