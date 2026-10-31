require_dependency "permissions/invocation_classifier"
require_dependency "permissions/policy_rule"

module Permissions
  class PolicyEvaluator
    LAYERS = %i[core provider resource instance team repository role agent lease invocation].freeze
    POLICY_RANK = { deny: 0, ask: 1, allow: 2 }.freeze

    Invocation = Data.define(:capability, :operation, :effects, :risk, :resource_scope, :classification) do
      def to_h
        { capability:, operation:, effects:, risk:, resource_scope:, classification: classification.to_h }
      end
    end
    Explanation = Data.define(:layer, :status, :rule, :policy, :detail) do
      def to_h = { layer:, status:, rule: rule&.to_h, policy:, detail: }
    end
    Decision = Data.define(:policy, :decisive_rule, :chain, :invocation) do
      def allow? = policy == :allow
      def ask? = policy == :ask
      def deny? = policy == :deny
      def to_h = { policy:, decisive_rule: decisive_rule&.to_h, chain: chain.map(&:to_h), invocation: invocation.to_h }
    end

    def initialize(descriptor:, role:, resource_scope:, rules: [], context: {}, arguments: {})
      @descriptor = descriptor
      @role = role.to_s
      @resource_scope = resource_scope
      @rules = Array(rules)
      @context = context.to_h.transform_keys(&:to_sym).merge(role: @role).freeze
      @arguments = arguments
    end

    def call
      classification = InvocationClassifier.call(descriptor: @descriptor, arguments: @arguments)
      normalized = @descriptor.resource_scope.normalize(@resource_scope, context: @context)
      return normalization_failure(classification, normalized) if normalized.fail_closed?

      invocation = Invocation.new(capability: @descriptor.capability, operation: classification.operation,
        effects: classification.effects, risk: classification.risk,
        resource_scope: normalized.value, classification: classification)
      match_statuses = @rules.to_h do |rule|
        [ rule, rule.match_status(invocation, descriptor: @descriptor, context: @context) ]
      end
      return matching_failure(invocation) if match_statuses.value?(:failure)

      matching = match_statuses.filter_map { |rule, status| rule if status == :match }
      selected = LAYERS.to_h { |layer| [ layer, select_rule(matching.select { |rule| rule.layer == layer }) ] }

      chain = LAYERS.map do |layer|
        rule = selected[layer]
        Explanation.new(layer:, status: rule ? :matched : :no_match, rule:, policy: rule&.policy,
          detail: rule ? :explicit_rule : :no_matching_rule)
      end

      deny = LAYERS.filter_map { |layer| selected[layer] }.find { |rule| rule.policy == :deny }
      return decision(:deny, deny, mark_decisive(chain, deny), invocation) if deny

      explicit = LAYERS.filter_map { |layer| selected[layer] }
      if explicit.empty?
        policy = @descriptor.defaults.fetch(@role, :deny)
        default = Explanation.new(layer: :default, status: :decisive_default, rule: nil, policy:, detail: :role_default)
        return decision(policy, nil, chain + [ default ], invocation)
      end

      effective = explicit.last
      ceiling = select_ceiling(matching.reject(&:delegable))
      if ceiling && POLICY_RANK.fetch(effective.policy) > POLICY_RANK.fetch(ceiling.policy)
        chain = mark_ceiling(chain, ceiling)
        effective = ceiling
      end
      chain = mark_decisive(chain, effective)
      decision(effective.policy, effective, chain, invocation)
    end

    private

    def select_rule(rules)
      rules.min_by do |rule|
        [ rule.policy == :deny ? 0 : 1, rule.specificity.map { |part| -part },
          POLICY_RANK.fetch(rule.policy), rule.id ]
      end
    end

    def select_ceiling(rules)
      rules.min_by do |rule|
        [ POLICY_RANK.fetch(rule.policy), LAYERS.index(rule.layer),
          rule.specificity.map { |part| -part }, rule.id ]
      end
    end

    def mark_ceiling(chain, ceiling)
      explanation = Explanation.new(layer: ceiling.layer, status: :decisive_ceiling,
        rule: ceiling, policy: ceiling.policy, detail: :non_delegable)
      return chain.map { |item| item.rule == ceiling ? explanation : item } if chain.any? { |item| item.rule == ceiling }

      chain.flat_map { |item| item.layer == ceiling.layer ? [ item, explanation ] : item }
    end

    def normalization_failure(classification, normalized)
      invocation = Invocation.new(capability: @descriptor.capability, operation: classification.operation,
        effects: classification.effects, risk: classification.risk, resource_scope: nil,
        classification: classification)
      explanation = Explanation.new(layer: :core, status: :decisive_failure, rule: nil,
        policy: :deny, detail: "resource_scope_#{normalized.status}".to_sym)
      decision(:deny, nil, [ explanation ], invocation)
    end

    def matching_failure(invocation)
      explanation = Explanation.new(layer: :core, status: :decisive_failure, rule: nil,
        policy: :deny, detail: :resource_scope_comparison_failed)
      decision(:deny, nil, [ explanation ], invocation)
    end

    def mark_decisive(chain, rule)
      chain.map do |item|
        next item unless item.rule == rule
        next item if item.status == :decisive_ceiling

        Explanation.new(layer: item.layer, status: :decisive, rule: item.rule,
          policy: item.policy, detail: item.detail)
      end
    end

    def decision(policy, rule, chain, invocation)
      Decision.new(policy:, decisive_rule: rule, chain: chain.freeze, invocation:)
    end
  end
end
