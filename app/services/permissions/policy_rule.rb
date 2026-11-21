require_dependency "permissions/capability_descriptor"

module Permissions
  class PolicyRule
    POLICIES = CapabilityDescriptor::POLICIES

    attr_reader :id, :layer, :policy, :capability, :operation, :resource_scope,
      :constraints, :selectors, :delegable, :source, :rationale, :duration

    # +duration+ is how long the authority behind this rule lasts: nil for a
    # durable rule (permanent), a lease's duration kind, or :invocation for a
    # one-call grant. The evaluator caps an allow by the descriptor's breadth
    # ceiling for that duration.
    def initialize(id:, layer:, policy:, source:, capability: nil, operation: nil,
      resource_scope: nil, constraints: {}, selectors: {}, delegable: true, rationale: nil, duration: nil, breadth: nil)
      @id = id.to_s.freeze
      @layer = layer.to_sym
      @policy = policy.to_sym
      @source = source.to_s.freeze
      @capability = capability&.to_s&.freeze
      @operation = operation&.to_s&.freeze
      @resource_scope = deep_freeze(resource_scope)
      @constraints = deep_freeze(constraints.to_h.transform_keys(&:to_s))
      @selectors = deep_freeze(selectors.to_h.transform_keys(&:to_sym))
      @delegable = !!delegable
      @rationale = rationale&.to_s&.freeze
      @duration = duration&.to_sym
      @breadth = breadth&.to_sym
      validate!
      freeze
    end

    def effective_duration = duration || (layer == :invocation ? :invocation : :permanent)

    def breadth = @breadth || CapabilityDescriptor.breadth_of(operation:, resource_scope:, constraints:)

    def matches?(invocation, descriptor:, context:, arguments: {})
      match_status(invocation, descriptor:, context:, arguments:) == :match
    end

    def match_status(invocation, descriptor:, context:, arguments: {})
      return :no_match if capability && !names?(capability, invocation.capability, descriptor&.capability_aliases)
      return :no_match if operation && !names?(operation, invocation.operation, descriptor&.operation_aliases)
      return :no_match unless selectors.all? { |key, expected| context.fetch(key, nil) == expected }
      return :no_match unless constraints.all? { |key, expected| constraint_satisfied?(key, expected, descriptor, arguments) }
      return :match unless resource_scope

      comparison = descriptor.resource_scope.compare(invocation.resource_scope, resource_scope, context: context)
      return :failure if comparison.fail_closed?

      %i[equal narrower].include?(comparison.value) ? :match : :no_match
    end

    # A `string_prefix` constraint stands for a family of invocations, matched a
    # token at a time rather than as raw text. Both halves of that matter:
    # comparing raw text would let `git commitfoo` satisfy a `git commit` rule,
    # and a descriptor only ever offers a prefix field for an argument it has
    # already established is safe to widen -- a command carrying shell syntax is
    # not projected at all, so there is nothing here for a rule to match and the
    # operator is asked again.
    def constraint_satisfied?(key, expected, descriptor, arguments)
      actual = arguments[key]
      return token_prefix?(actual, expected) if descriptor.constraint_fields[key.to_s] == :string_prefix

      actual == expected
    end

    def token_prefix?(actual, expected)
      expected_tokens = expected.to_s.split
      actual_tokens = actual.to_s.split
      return false if expected_tokens.empty? || actual_tokens.empty?

      actual_tokens.first(expected_tokens.length) == expected_tokens
    end

    # Explicit fields make a rule narrower. The stable id is intentionally not
    # part of specificity; equally specific conflicts resolve toward less authority.
    def specificity
      dimensions = [ selectors.length + constraints.length, resource_scope ? 1 : 0, operation ? 1 : 0, capability ? 1 : 0 ]
      [ dimensions.sum, *dimensions ]
    end

    def to_h
      { id: id, layer: layer, policy: policy, source: source, capability: capability,
        operation: operation, resource_scope: resource_scope, constraints: constraints, selectors: selectors,
        delegable: delegable, rationale: rationale }
    end

    private

    # A rule written for an identifier the descriptor has since renamed still
    # names it through the descriptor's aliases (CapabilityDescriptor#names_*).
    def names?(rule_identifier, invocation_identifier, aliases)
      rule_identifier == invocation_identifier || Array(aliases).include?(rule_identifier)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [ deep_freeze(key), deep_freeze(item) ] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end

    def validate!
      raise ArgumentError, "policy rule id is required" if id.empty?
      raise ArgumentError, "policy rule source is required" if source.empty?
      raise ArgumentError, "unknown policy: #{policy}" unless POLICIES.include?(policy)
      raise ArgumentError, "unknown policy layer: #{layer}" unless PolicyEvaluator::LAYERS.include?(layer)
    end
  end
end
