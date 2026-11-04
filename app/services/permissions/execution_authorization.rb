module Permissions
  # Decides whether a host, container, or provider-native effect may proceed.
  #
  # Rules come from the caller (the owner's durable rules) and are evaluated by
  # +PolicyEvaluator+ like every other capability. Two further limits apply:
  #
  # 1. Sensitive effects (credential use, privilege change, destructive or
  #    external writes) that were only allowed by the descriptor default, not by
  #    an explicit rule, are lowered to +ask+.
  # 2. A descriptor's fresh-authentication window lowers +allow+ to +ask+ when
  #    the approver's +authenticated_at+ is not recent enough.
  # 3. +ExecutionCeiling+ limits (confinement, network profile, provider
  #    ceilings) then lower the result further. They can never raise it.
  class ExecutionAuthorization
    Result = Data.define(:decision, :policy, :ceilings, :subject, :fresh_authentication, :reservation) do
      def initialize(fresh_authentication: nil, reservation: nil, **attributes) = super

      def allowed? = policy == :allow
      def ask? = policy == :ask
      def denied? = policy == :deny
      def to_h = { policy:, ceilings: ceilings.map(&:to_h), decision: decision.to_h, fresh_authentication: fresh_authentication&.to_h }
    end

    def self.authorize(...) = new(...).authorize

    def initialize(subject:, role:, owner: nil, rules: [], ceiling: ExecutionCeiling.default, context: {}, selector_contexts: nil, authenticated_at: nil)
      @authenticated_at = authenticated_at
      @owner = owner
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
      decisions = @contexts.map { |context| [ context, authorization_for(descriptor, arguments, context, consume: false) ] }
      winning_context, authorization = decisions.min_by do |_context, candidate|
        [ PolicyEvaluator::POLICY_RANK.fetch(candidate.decision.policy), candidate.decision.decisive_rule ? 0 : 1 ]
      end
      decision = authorization.decision
      policy, fresh, applied = effective_policy(descriptor, decision)
      reservation = nil

      if @owner && policy == :allow
        authorization = authorization_for(descriptor, arguments, winning_context, consume: true)
        decision = authorization.decision
        policy, fresh, applied = effective_policy(descriptor, decision)
        reservation = authorization.reservation if policy == :allow && authorization.lease
      end

      # Budget observers see the outcome only; they cannot change it.
      EffectMetadata.notify(descriptor, decision, policy:)
      Result.new(decision:, policy:, ceilings: applied, subject: @subject, fresh_authentication: fresh, reservation:)
    end

    private

    Authorization = Data.define(:decision, :lease) do
      def reservation = LeaseAuthorizer::Reservation.new(lease)
    end

    def effective_policy(descriptor, decision)
      effects = decision.invocation.effects
      policy = decision.policy

      if policy == :allow && decision.decisive_rule.nil? && (effects & ExecutionActions::SENSITIVE_EFFECTS).any?
        policy = :ask
      end

      policy, fresh = FreshAuthentication.apply(policy, descriptor:, authenticated_at: @authenticated_at)
      policy, applied = @ceiling.apply(policy, effects:, subject: @subject)
      [ policy, fresh, applied ]
    end

    def authorization_for(descriptor, arguments, selector_context, consume:)
      context = @context.merge(selector_context)
      unless @owner
        decision = PolicyEvaluator.new(descriptor:, role: @role, resource_scope: {}, rules: @rules, context:, arguments:).call
        return Authorization.new(decision:, lease: nil)
      end

      method = consume ? :call : :explain
      result = LeaseAuthorizer.public_send(method, descriptor:, owner: @owner, role: @role, resource_scope: {},
        rules: @rules, context:, arguments:)
      Authorization.new(decision: result.decision, lease: result.lease)
    end
  end
end
