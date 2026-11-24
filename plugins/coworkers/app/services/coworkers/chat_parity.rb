module Coworkers
  # The coworkers plugin's side of interactive chat tool parity (see
  # Mcp::ChatToolParity, which is generic and knows nothing of coworkers).
  #
  # Coworkers share the ordinary chat tool surface. This participant owns the
  # coworker context, its reviewed exceptions over core tools, and the coworker
  # specific reason codes. Authorization stays with the canonical permission
  # descriptors, operator identity (`user.admin?`), grants, and resource access
  # -- never with coworker identity. It is contributed through
  # Coworkers::ChatToolSet, so it is only active while the plugin is enabled.
  module ChatParity
    CONTEXT = :coworker
    CORE_CONTEXTS = %i[planner coding local].freeze
    ALL_CONTEXTS = :all
    SPEC = "plugins/coworkers/spec/services/coworkers/chat_parity_spec.rb".freeze

    REASON_CODES = {
      "owner_permission_decision" =>
        "Owner-side permission grant/deny/lease decisions that a coworker must not make for itself.",
      "coworker_identity_lifecycle" =>
        "Coworker workspace and identity lifecycle operations that have no non-coworker subject.",
      "coworker_sanitized_surface" =>
        "Coworker-only repository-read or sanitized-diagnostic variant of a tool whose canonical form is shared."
    }.freeze

    # Owners decide permissions; a coworker cannot grant itself access.
    PERMISSION_TOOLS = %w[
      list_permissions explain_permission grant_permission deny_permission revoke_permission
      create_permission_lease revoke_permission_lease apply_permission_preset cancel_authorization_request
    ].freeze

    # Coworker-only tools that exist beside the shared catalog.
    SANITIZED_TOOLS = %w[
      list_repository_files read_repository_file search_repository_code
      read_backend_exception_events read_browser_error_events read_performance_log_events
    ].freeze

    LIFECYCLE_TOOLS = %w[
      discover_coworker_capabilities surrender_permission_lease request_permission_revocation
    ].freeze

    # Bound to one coworker-review run (Coworkers::ReviewToolSet).
    VERDICT_TOOLS = %w[submit_coworker_review].freeze

    EXCEPTIONS = [
      {
        reason_code: "workflow_run_bound_verdict",
        explanation: "The coworker review verdict is bound to one reviewer run, not an interactive chat.",
        owner: "coworkers", test_ref: SPEC, absent_from: [ ALL_CONTEXTS ], tools: VERDICT_TOOLS
      },
      {
        reason_code: "owner_permission_decision",
        explanation: "A coworker must not grant, deny, lease, or revoke its own permissions; the owner decides.",
        owner: "coworkers", test_ref: SPEC, absent_from: [ CONTEXT ], tools: PERMISSION_TOOLS
      },
      {
        reason_code: "coworker_sanitized_surface",
        explanation: "Coworker-scoped repository reads and sanitized diagnostics, authorized by coworker grants.",
        owner: "coworkers", test_ref: SPEC, absent_from: CORE_CONTEXTS, tools: SANITIZED_TOOLS
      },
      {
        reason_code: "coworker_identity_lifecycle",
        explanation: "Requests addressed to the coworker's owner have no subject outside a coworker chat.",
        owner: "coworkers", test_ref: SPEC, absent_from: CORE_CONTEXTS, tools: LIFECYCLE_TOOLS
      }
    ].freeze

    REMOVED_PROVIDER_APIS = %i[coworker_excluded? coworker_specific_availability?].freeze
    REMOVED_DEFINITION_KEYS = %w[coworker_excluded].freeze

    class << self
      def context = CONTEXT
      def enabled? = Coworkers.enabled?
      def reason_codes = REASON_CODES
      def exceptions = EXCEPTIONS

      def validate_provider!(provider)
        return unless REMOVED_PROVIDER_APIS.any? { |api| provider.respond_to?(api) }

        raise ArgumentError, "#{provider} uses a removed boolean coworker exclusion API; declare " \
          "`chat_parity_exceptions` with reason_code, explanation, owner and test_ref"
      end

      def validate_definition!(definition)
        return unless REMOVED_DEFINITION_KEYS.any? { |key| definition.key?(key.to_sym) || definition.key?(key) }

        raise ArgumentError, "definition #{definition[:name] || definition['name']} uses removed `coworker_excluded`; " \
          "declare `parity_exception` with reason_code, explanation, owner and test_ref"
      end

      # A provider whose reviewed exceptions hide it from every core context
      # exists only for coworkers and answers `available_for_coworker?`; every
      # other provider uses its ordinary availability.
      def provider_available?(tool_set, chat_session, tier:)
        if coworker_only?(tool_set) && tool_set.respond_to?(:available_for_coworker?)
          tool_set.available_for_coworker?(chat_session, tier:)
        else
          tool_set.available_for?(chat_session, tier:)
        end
      end

      def coworker_only?(tool_set)
        Mcp::ChatToolParity.provider_exceptions(tool_set).any? do |exception|
          CORE_CONTEXTS.all? { |context| exception.absent_from?(context) }
        end
      end
    end
  end
end
