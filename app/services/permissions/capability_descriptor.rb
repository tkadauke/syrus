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

    # Effects that cross a real consequence barrier. An operation declaring
    # none of them has no consequence outside the agent's bounded internal
    # work; internal persistence alone (internal_write) is not a barrier.
    BARRIER_EFFECTS = %i[
      credential_use external_write communication financial privilege_change
      operational destructive irreversible persistent_autonomy operator_host_access
    ].freeze

    # Why an operation without a barrier effect is nevertheless deniable. Every
    # such operation must name one, so "the default happened to be ask" can
    # never be the classification.
    DENIABLE_REASONS = %i[
      material_control privilege_change shared_state confidential_cross_boundary
      instance_wide_observability external_ingestion autonomy_expansion operator_scoping
    ].freeze

    # How broadly a rule or lease may target an operation, broadest first.
    BREADTHS = %i[family tool resource].freeze

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
      :resource_scope_resolver, :essential, :deniable_reason, :breadth_ceilings
    attr_reader :presentation

    def initialize(capability:, operation:, effects:, risk:, requestable_roles:, defaults:,
      maximum_autonomy:, authority_durations:, resource_scope:, classifier:,
      fingerprint_normalizer:, redactor:, maximum_duration: nil, presets: [],
      capability_aliases: [], operation_aliases: [], constraint_fields: {},
      fresh_authentication_window: nil, budget_dimensions: [], benign_internal: nil, tool_set_bundle: nil,
      resource_scope_resolver: nil, presentation: nil, essential: false, deniable_reason: nil, breadth_ceilings: nil)
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
      @breadth_ceilings = normalize_breadth_ceilings(breadth_ceilings)
      # Every ordinary operation can be allowed forever; breadth_ceilings is
      # the one place a descriptor narrows that (raw SQL: once for the family,
      # forever for one database). The overall autonomy ceiling and the
      # durations a grant may name follow from the broadest ceiling. Only an
      # operation that must never be delegated at all (maximum_autonomy :none)
      # keeps its declared durations.
      if maximum_autonomy.to_sym == :none
        @maximum_autonomy = :none
        @authority_durations = Array(authority_durations).map(&:to_sym).uniq.freeze
      else
        rank = AUTONOMY_CEILINGS.each_with_index.to_h
        @maximum_autonomy = @breadth_ceilings.values.max_by { |ceiling| rank.fetch(ceiling) }
        @authority_durations = AUTHORITY_DURATIONS.select { |duration| rank.fetch(duration) <= rank.fetch(@maximum_autonomy) }.freeze
      end
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
      @essential = essential == true
      @deniable_reason = deniable_reason&.to_sym
      @capability_aliases = aliases(capability_aliases, :capability_aliases)
      @operation_aliases = aliases(operation_aliases, :operation_aliases)
      validate!
      freeze
    end

    def requires_fresh_authentication? = !fresh_authentication_window.nil?

    # A non-deniable agent essential: still evaluated and audited by the
    # permission system, but no rule, preset, lease or request can change the
    # outcome. See config/syrus_docs/permission_authority.md.
    def essential? = essential

    # Stored rules keep the identifiers they were written with. A rename that
    # lists the old identifier as an alias is the same capability or operation
    # (CapabilityUpgradeValidator rejects one that widens), so it must still
    # match them (formal/SyrusModel/RuleAliases.lean).
    def names_capability?(identifier) = identifier == capability || capability_aliases.include?(identifier)
    def names_operation?(identifier) = identifier == operation || operation_aliases.include?(identifier)

    def barrier_effects = effects & BARRIER_EFFECTS

    # The longest authority a rule or lease of the given breadth may carry.
    def breadth_ceiling(breadth) = breadth_ceilings.fetch(breadth.to_sym)

    # Whether authority of +duration+ may be granted at +breadth+.
    def breadth_permits?(breadth, duration)
      rank = AUTONOMY_CEILINGS.each_with_index.to_h
      rank.fetch(duration.to_sym) <= rank.fetch(breadth_ceiling(breadth))
    end

    # The breadth a rule targets: a resource scope or argument constraint makes
    # it resource-level, an operation tool-level, a capability alone family-level.
    def self.breadth_of(operation:, resource_scope:, constraints: nil)
      return :resource if resource_scope.present? || constraints.present?
      return :tool if operation.present?

      :family
    end

    def classify(arguments) = classifier.call(arguments)
    def normalize_fingerprint(arguments) = fingerprint_normalizer.call(arguments)
    def redact(arguments) = redactor.call(arguments)
    def resource_scope_for(arguments) = resource_scope_resolver ? resource_scope_resolver.call(arguments) : {}
    def role_recommendations = defaults

    def contract_key
      [
        *authorization_contract_key,
        requestable_roles.sort, defaults.sort
      ]
    end

    def authorization_contract_key
      [
        capability, effects.sort, risk, maximum_autonomy, authority_durations.sort,
        maximum_duration, resource_scope.type, resource_scope.options,
        presets,
        capability_aliases.sort, operation_aliases.sort, constraint_fields.sort,
        fresh_authentication_window, budget_dimensions.sort, benign_internal,
        breadth_ceilings.sort
        # essential and deniable_reason are deliberately not part of the
        # contract: they classify one tool on one surface (a coworker sees the
        # same operation as a chat, under the operator's delegation scope).
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
        essential: essential,
        deniable_reason: deniable_reason,
        breadth_ceilings: breadth_ceilings,
        presentation: presentation.to_h
      }
    end

    private

    # Ordinary operations may be allowed forever at every breadth; a descriptor
    # narrows only where a broad grant would be unsafe (for example raw SQL:
    # once for the family and the tool, forever for one named database).
    def normalize_breadth_ceilings(ceilings)
      defaults = BREADTHS.index_with { :permanent }
      return defaults.freeze if ceilings.nil?

      defaults.merge(ceilings.to_h.transform_keys(&:to_sym).transform_values(&:to_sym)).freeze
    end

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
      unknown_breadths = breadth_ceilings.keys - BREADTHS
      raise ArgumentError, "unknown breadths: #{unknown_breadths.join(', ')}" if unknown_breadths.any?
      unknown_ceilings = breadth_ceilings.values - AUTONOMY_CEILINGS
      raise ArgumentError, "unknown breadth ceilings: #{unknown_ceilings.join(', ')}" if unknown_ceilings.any?
      if deniable_reason && !DENIABLE_REASONS.include?(deniable_reason)
        raise ArgumentError, "unknown deniable reason: #{deniable_reason}"
      end
      if essential
        raise ArgumentError, "essential operations cannot declare barrier effects: #{barrier_effects.join(', ')}" if barrier_effects.any?
        raise ArgumentError, "essential operations cannot carry a deniable reason" if deniable_reason
      end
    end
  end
end
