require "digest"
require_dependency "permissions/resource_scope_schema"

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

    ResourceScope = ResourceScopeSchema

    attr_reader :capability, :operation, :effects, :risk, :requestable_roles,
      :defaults, :maximum_autonomy, :authority_durations, :maximum_duration,
      :resource_scope, :classifier, :fingerprint_normalizer, :redactor, :presets,
      :capability_aliases, :operation_aliases

    def initialize(capability:, operation:, effects:, risk:, requestable_roles:, defaults:,
      maximum_autonomy:, authority_durations:, resource_scope:, classifier:,
      fingerprint_normalizer:, redactor:, maximum_duration: nil, presets: [],
      capability_aliases: [], operation_aliases: [])
      @capability = versioned_identifier(capability, :capability)
      @operation = versioned_identifier(operation, :operation)
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
      @presets = Array(presets).freeze
      @capability_aliases = aliases(capability_aliases, :capability_aliases)
      @operation_aliases = aliases(operation_aliases, :operation_aliases)
      validate!
      freeze
    end

    def classify(arguments) = classifier.call(arguments)
    def normalize_fingerprint(arguments) = fingerprint_normalizer.call(arguments)
    def redact(arguments) = redactor.call(arguments)
    def role_recommendations = defaults

    def contract_key
      [
        capability, effects.sort, risk, maximum_autonomy, authority_durations.sort,
        maximum_duration, resource_scope.type, resource_scope.options,
        requestable_roles.sort, defaults.sort, presets,
        capability_aliases.sort, operation_aliases.sort
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
        presets: presets,
        capability_aliases: capability_aliases,
        operation_aliases: operation_aliases
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
      %i[classifier fingerprint_normalizer redactor].each do |hook|
        raise ArgumentError, "#{hook} must respond to call" unless public_send(hook).respond_to?(:call)
      end
    end
  end
end
