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

    def initialize(subject:, role:, rules: [], ceiling: ExecutionCeiling.default, context: {}, selector_contexts: nil)
      @subject = subject
      @role = role.to_s
      @rules = rules
      @ceiling = ceiling
      @context = context
      # A rule's selectors compare against one subject description, but one
      # process matches several (its role, its repository-scoped role, its
      # agent). Each is evaluated and the strictest outcome wins.
      @contexts = Array(selector_contexts).presence || [ context ]
    end

    def authorize
      descriptor = ExecutionActions.descriptor_for(@subject.location)
      arguments = ExecutionActions.arguments_for(@subject)
      decision = @contexts.map do |context|
        PolicyEvaluator.new(
          descriptor:, role: @role, resource_scope: {}, rules: @rules, context: @context.merge(context), arguments:
        ).call
      end.min_by { |candidate| PolicyEvaluator::POLICY_RANK.fetch(candidate.policy) }
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
