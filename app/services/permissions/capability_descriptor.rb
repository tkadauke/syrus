require "digest"
require_dependency "permissions/resource_scope_schema"
require_dependency "permissions/tool_set_bundles"
require_dependency "permissions/capability_presentation"

module Permissions
  class CapabilityDescriptor
    VERSION = 1
    EFFECTS = %i[
      local_read isolated_workspace_write isolated_execution network_read
      confidential_read credential_use internal_write external_write communication
      financial privilege_change operational destructive irreversible
      persistent_autonomy operator_host_access
    ].freeze
    RISKS = %i[low medium high critical].freeze
    POLICIES = %i[deny ask allow].freeze
    AUTONOMY_CEILINGS = %i[none invocation chat_session job permanent].freeze
    AUTHORITY_DURATIONS = %i[invocation chat_session job permanent].freeze
    # What a future budget control may meter. Pure metadata: declaring a
    # dimension never grants, widens, or narrows authority.
    BUDGET_DIMENSIONS = %i[model_tokens compute_time network_egress external_spend storage].freeze

    # Internal writes that are provably benign for default-allow purposes. An
    # `internal_write` effect alone is never benign; a descriptor must name
    # which bounded, reversible, user-authorized kind it is.
    BENIGN_INTERNAL_KINDS = %i[context_binding owner_interaction authority_reduction draft_proposal].freeze

    # Argument types a descriptor may expose as durable-authority constraints.
    # `string_prefix` is matched as a token prefix rather than for equality, so
    # one rule can stand for a family of invocations ("every `git commit ...`")
    # instead of a single exact one. A descriptor that declares such a field is
    # promising that the argument it projects is safe to widen this way: see
    # PolicyRule#constraint_satisfied? for the matching rule, and note that a
    # prefix field is deliberately excluded from an invocation's identity.
    CONSTRAINT_TYPES = %i[string integer boolean string_prefix].freeze

    ResourceScope = ResourceScopeSchema

    attr_reader :capability, :operation, :effects, :risk, :requestable_roles,
      :defaults, :maximum_autonomy, :authority_durations, :maximum_duration,
      :resource_scope, :classifier, :fingerprint_normalizer, :redactor, :presets,
      :capability_aliases, :operation_aliases, :constraint_fields,
      :fresh_authentication_window, :budget_dimensions, :benign_internal, :tool_set_bundle,
      :resource_scope_resolver
    attr_reader :presentation

    def initialize(capability:, operation:, effects:, risk:, requestable_roles:, defaults:,
      maximum_autonomy:, authority_durations:, resource_scope:, classifier:,
      fingerprint_normalizer:, redactor:, maximum_duration: nil, presets: [],
      capability_aliases: [], operation_aliases: [], constraint_fields: {},
      fresh_authentication_window: nil, budget_dimensions: [], benign_internal: nil, tool_set_bundle: nil,
      resource_scope_resolver: nil, presentation: nil)
      @capability = versioned_identifier(capability, :capability)
      @operation = versioned_identifier(operation, :operation)
      @presentation = if presentation.is_a?(CapabilityPresentation)
        presentation
      elsif presentation
        CapabilityPresentation.new(**presentation.to_h.symbolize_keys)
      elsif Rails.env.test?
        # Existing isolated unit fixtures may omit UI metadata. Production
        # registries are architecture-checked and must declare it explicitly.
        CapabilityPresentation.for(capability: @capability, operation: @operation)
      else
        raise ArgumentError, "presentation copy is required"
      end
      @effects = Array(effects).map(&:to_sym).uniq.freeze
      @risk = risk.to_sym
      @requestable_roles = Array(requestable_roles).map(&:to_s).uniq.freeze
      @defaults = defaults.to_h.transform_keys(&:to_s).transform_values(&:to_sym).freeze
      @maximum_autonomy = maximum_autonomy.to_sym
      @authority_durations = Array(authority_durations).map(&:to_sym).uniq.freeze
      @maximum_duration = maximum_duration
      @resource_scope = resource_scope.is_a?(ResourceScopeSchema) ? resource_scope : ResourceScopeSchema.new(**resource_scope)
      @classifier = classifier
      @fingerprint_normalizer = fingerprint_normalizer
      @redactor = redactor
      @resource_scope_resolver = resource_scope_resolver
      @presets = Array(presets).freeze
      @constraint_fields = constraint_fields.to_h.to_h { |name, type| [ name.to_s.freeze, type.to_sym ] }.freeze
      @fresh_authentication_window = fresh_authentication_window
      @budget_dimensions = Array(budget_dimensions).map(&:to_sym).uniq.freeze
      @benign_internal = benign_internal&.to_sym
      @tool_set_bundle = (tool_set_bundle.presence || ToolSetBundles.classify(@effects)).to_s.freeze
      @capability_aliases = aliases(capability_aliases, :capability_aliases)
      @operation_aliases = aliases(operation_aliases, :operation_aliases)
      validate!
      freeze
    end

    def requires_fresh_authentication? = !fresh_authentication_window.nil?

    def classify(arguments) = classifier.call(arguments)
    def normalize_fingerprint(arguments) = fingerprint_normalizer.call(arguments)
    def redact(arguments) = redactor.call(arguments)
    def resource_scope_for(arguments) = resource_scope_resolver ? resource_scope_resolver.call(arguments) : {}
    def role_recommendations = defaults

    def contract_key
      [
        capability, effects.sort, risk, maximum_autonomy, authority_durations.sort,
        maximum_duration, resource_scope.type, resource_scope.options,
        requestable_roles.sort, defaults.sort, presets,
        capability_aliases.sort, operation_aliases.sort, constraint_fields.sort,
        fresh_authentication_window, budget_dimensions.sort, benign_internal
      ]
    end

    def to_h
      {
        capability: capability,
        operation: operation,
        effects: effects,
        risk: risk,
        requestable_roles: requestable_roles,
        defaults: defaults,
        maximum_autonomy: maximum_autonomy,
        authority_durations: authority_durations,
        maximum_duration: maximum_duration,
        resource_scope: resource_scope.to_h,
        classifier: classifier,
        fingerprint_normalizer: fingerprint_normalizer,
        redactor: redactor,
        resource_scope_resolver: resource_scope_resolver,
        presets: presets,
        capability_aliases: capability_aliases,
        operation_aliases: operation_aliases,
        constraint_fields: constraint_fields,
        fresh_authentication_window: fresh_authentication_window,
        budget_dimensions: budget_dimensions,
        benign_internal: benign_internal,
        tool_set_bundle: tool_set_bundle,
        presentation: presentation.to_h
      }
    end

    private

    def versioned_identifier(value, field)
      identifier = value.to_s
      unless identifier.match?(/\A[a-z][a-z0-9_.-]*(?:\/[a-z][a-z0-9_.-]*)?@v[1-9]\d*\z/)
        raise ArgumentError, "#{field} must be a versioned identifier (for example syrus.jobs@v1)"
      end
      identifier.freeze
    end

    def aliases(values, field)
      Array(values).map { |value| versioned_identifier(value, field) }.tap do |identifiers|
        raise ArgumentError, "#{field} must not contain duplicates" if identifiers.uniq.length != identifiers.length
      end.freeze
    end

    def validate!
      unknown_effects = effects - EFFECTS
      raise ArgumentError, "unknown effects: #{unknown_effects.join(', ')}" if unknown_effects.any?
      raise ArgumentError, "unknown risk: #{risk}" unless RISKS.include?(risk)
      raise ArgumentError, "unknown maximum autonomy: #{maximum_autonomy}" unless AUTONOMY_CEILINGS.include?(maximum_autonomy)
      unknown_durations = authority_durations - AUTHORITY_DURATIONS
      raise ArgumentError, "unknown authority durations: #{unknown_durations.join(', ')}" if unknown_durations.any?
      unknown_policies = defaults.values - POLICIES
      raise ArgumentError, "unknown default policies: #{unknown_policies.join(', ')}" if unknown_policies.any?
      missing_defaults = requestable_roles - defaults.keys
      raise ArgumentError, "missing role defaults: #{missing_defaults.join(', ')}" if missing_defaults.any?
      raise ArgumentError, "capability aliases must not include the canonical identifier" if capability_aliases.include?(capability)
      raise ArgumentError, "operation aliases must not include the canonical identifier" if operation_aliases.include?(operation)
      unknown_constraints = constraint_fields.reject { |_name, type| CONSTRAINT_TYPES.include?(type) }
      raise ArgumentError, "unknown constraint field types: #{unknown_constraints.keys.join(', ')}" if unknown_constraints.any?
      sensitive = constraint_fields.keys.grep(ToolPayloadRedactor::SENSITIVE_KEY)
      raise ArgumentError, "constraint fields must not expose secrets: #{sensitive.join(', ')}" if sensitive.any?
      unless fresh_authentication_window.nil? ||
          (fresh_authentication_window.respond_to?(:to_f) && !fresh_authentication_window.is_a?(String) && fresh_authentication_window.to_f >= 0)
        raise ArgumentError, "fresh authentication window must be a non-negative duration"
      end
      unknown_budget = budget_dimensions - BUDGET_DIMENSIONS
      raise ArgumentError, "unknown budget dimensions: #{unknown_budget.join(', ')}" if unknown_budget.any?
      ToolSetBundles.fetch(tool_set_bundle)
      expected_bundle = ToolSetBundles.classify(effects) if effects.present?
      if expected_bundle && tool_set_bundle != expected_bundle
        raise ArgumentError, "tool-set bundle #{tool_set_bundle.inspect} conflicts with effect-derived #{expected_bundle.inspect}"
      end
      if benign_internal
        raise ArgumentError, "unknown benign internal kind: #{benign_internal}" unless BENIGN_INTERNAL_KINDS.include?(benign_internal)
        unless risk == :low && (effects - %i[internal_write local_read]).empty? && effects.include?(:internal_write)
          raise ArgumentError, "benign internal descriptors must be low risk and limited to internal_write/local_read effects"
        end
      end
      %i[classifier fingerprint_normalizer redactor].each do |hook|
        raise ArgumentError, "#{hook} must respond to call" unless public_send(hook).respond_to?(:call)
      end
      if resource_scope_resolver && !resource_scope_resolver.respond_to?(:call)
        raise ArgumentError, "resource_scope_resolver must respond to call"
      end
    end
  end
end
