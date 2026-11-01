require "digest"

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

    ResourceScope = Data.define(:type, :options, :label, :validate, :normalize) do
      def initialize(type: :none, options: nil, label: nil, validate: nil, normalize: nil)
        super(type: type.to_sym, options: options, label: label, validate: validate, normalize: normalize)
      end

      def to_h
        { type: type, options: options, label: label, validate: validate, normalize: normalize }
      end
    end

    attr_reader :capability, :operation, :effects, :risk, :requestable_roles,
      :defaults, :maximum_autonomy, :authority_durations, :maximum_duration,
      :resource_scope, :classifier, :fingerprint_normalizer, :redactor, :presets

    def initialize(capability:, operation:, effects:, risk:, requestable_roles:, defaults:,
      maximum_autonomy:, authority_durations:, resource_scope:, classifier:,
      fingerprint_normalizer:, redactor:, maximum_duration: nil, presets: [])
      @capability = versioned_identifier(capability, :capability)
      @operation = versioned_identifier(operation, :operation)
      @effects = Array(effects).map(&:to_sym).uniq.freeze
      @risk = risk.to_sym
      @requestable_roles = Array(requestable_roles).map(&:to_s).uniq.freeze
      @defaults = defaults.to_h.transform_keys(&:to_s).transform_values(&:to_sym).freeze
      @maximum_autonomy = maximum_autonomy.to_sym
      @authority_durations = Array(authority_durations).map(&:to_sym).uniq.freeze
      @maximum_duration = maximum_duration
      @resource_scope = resource_scope.is_a?(ResourceScope) ? resource_scope : ResourceScope.new(**resource_scope)
      @classifier = classifier
      @fingerprint_normalizer = fingerprint_normalizer
      @redactor = redactor
      @presets = Array(presets).freeze
      validate!
      freeze
    end

    def classify(arguments) = classifier.call(arguments)
    def normalize_fingerprint(arguments) = fingerprint_normalizer.call(arguments)
    def redact(arguments) = redactor.call(arguments)

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
        presets: presets
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
      %i[classifier fingerprint_normalizer redactor].each do |hook|
        raise ArgumentError, "#{hook} must respond to call" unless public_send(hook).respond_to?(:call)
      end
    end
  end
end
