require_dependency "permissions/capability_descriptor"

module Permissions
  class PolicyRule
    POLICIES = CapabilityDescriptor::POLICIES

    attr_reader :id, :layer, :policy, :capability, :operation, :resource_scope,
      :selectors, :delegable, :source, :rationale

    def initialize(id:, layer:, policy:, source:, capability: nil, operation: nil,
      resource_scope: nil, selectors: {}, delegable: true, rationale: nil)
      @id = id.to_s.freeze
      @layer = layer.to_sym
      @policy = policy.to_sym
      @source = source.to_s.freeze
      @capability = capability&.to_s&.freeze
      @operation = operation&.to_s&.freeze
      @resource_scope = deep_freeze(resource_scope)
      @selectors = deep_freeze(selectors.to_h.transform_keys(&:to_sym))
      @delegable = !!delegable
      @rationale = rationale&.to_s&.freeze
      validate!
      freeze
    end

    def matches?(invocation, descriptor:, context:)
      match_status(invocation, descriptor:, context:) == :match
    end

    def match_status(invocation, descriptor:, context:)
      return :no_match if capability && capability != invocation.capability
      return :no_match if operation && operation != invocation.operation
      return :no_match unless selectors.all? { |key, expected| context.fetch(key, nil) == expected }
      return :match unless resource_scope

      comparison = descriptor.resource_scope.compare(invocation.resource_scope, resource_scope, context: context)
      return :failure if comparison.fail_closed?

      %i[equal narrower].include?(comparison.value) ? :match : :no_match
    end

    # Explicit fields make a rule narrower. The stable id is intentionally not
    # part of specificity; equally specific conflicts resolve toward less authority.
    def specificity
      dimensions = [ selectors.length, resource_scope ? 1 : 0, operation ? 1 : 0, capability ? 1 : 0 ]
      [ dimensions.sum, *dimensions ]
    end

    def to_h
      { id: id, layer: layer, policy: policy, source: source, capability: capability,
        operation: operation, resource_scope: resource_scope, selectors: selectors,
        delegable: delegable, rationale: rationale }
    end

    private

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
