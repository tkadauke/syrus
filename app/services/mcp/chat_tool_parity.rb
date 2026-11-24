module Mcp
  # Interactive chat tool parity.
  #
  # Every tool meaningful in an interactive chat is discoverable in planner,
  # coding, local, and coworker chats when its feature/plugin is enabled.
  # Authorization comes from canonical capability descriptors, operator
  # identity, grants, resource access, and runtime state -- never from the
  # coworker/non-coworker distinction. Discovery parity and authorization
  # policy stay separate: a risky, destructive, admin, external-write, or
  # credential-using tool is not an exception merely because it is risky.
  #
  # A role-specific exception is allowed only when the operation is
  # semantically incoherent in the other context. Every exception carries a
  # stable reason code, a human explanation, a responsible owner, and a
  # regression test reference. Bare exclusion booleans, anonymous name lists,
  # and silent role-only registrations are forbidden; `ReviewedException.build`
  # refuses an incomplete declaration and `ChatToolParity.report` flags
  # unexplained differences in either direction.
  module ChatToolParity
    CONTEXTS = %i[planner coding local coworker].freeze

    # The only reasons a role-specific exception may cite. Adding a code is a
    # reviewed change to this list.
    REASON_CODES = {
      "owner_permission_decision" =>
        "Owner-side permission grant/deny/lease decisions that a coworker must not make for itself.",
      "workflow_run_bound_verdict" =>
        "Workflow verdict/callback tools bound to one specific reviewer or evaluator run.",
      "evaluator_run_bound" =>
        "Tools bound to the disposable scoped-event evaluator, which has no coworker counterpart.",
      "requires_coding_checkout" =>
        "Operation needs a Coding Mode checkout or runtime session that the other chat context does not have.",
      "requires_local_checkout" =>
        "Operation needs a Local Mode daemon workspace that the other chat context does not have.",
      "coworker_identity_lifecycle" =>
        "Coworker workspace and identity lifecycle operations that have no non-coworker subject.",
      "coworker_sanitized_surface" =>
        "Coworker-only repository-read or sanitized-diagnostic variant of a tool whose canonical form is shared."
    }.freeze

    # +absent_from+ names the contexts (of CONTEXTS) where the tool is
    # legitimately absent; +tools+ names the tools covered.
    ReviewedException = Data.define(:reason_code, :explanation, :owner, :test_ref, :absent_from, :tools) do
      def self.build(reason_code: nil, explanation: nil, owner: nil, test_ref: nil, absent_from: [], tools: [])
        attributes = { reason_code: reason_code.to_s, explanation: explanation.to_s, owner: owner.to_s,
                       test_ref: test_ref.to_s }
        missing = attributes.select { |_, value| value.strip.empty? }.keys
        raise ArgumentError, "chat tool parity exception is missing #{missing.join(', ')}" if missing.any?
        unless REASON_CODES.key?(attributes[:reason_code])
          raise ArgumentError, "unknown chat tool parity reason code #{attributes[:reason_code].inspect}"
        end

        absent = Array(absent_from).map(&:to_sym)
        unknown = absent - CONTEXTS
        raise ArgumentError, "unknown parity contexts #{unknown.inspect}" if unknown.any?

        new(**attributes, absent_from: absent.freeze, tools: Array(tools).map(&:to_s).freeze)
      end

      # Accepts an ReviewedException or a plain hash, which is what a plugin returns
      # so it does not need a core constant.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise ArgumentError, "chat tool parity exception must be a hash with metadata, got #{value.inspect}" unless value.respond_to?(:to_h)

        build(**value.to_h.symbolize_keys)
      end
    end

    # Owners decide permissions; a coworker cannot grant itself access.
    PERMISSION_TOOLS = %w[
      list_permissions explain_permission grant_permission deny_permission revoke_permission
      create_permission_lease revoke_permission_lease apply_permission_preset cancel_authorization_request
    ].freeze

    WORKFLOW_VERDICT_TOOLS = %w[
      submit_summary submit_test_plan submit_report patch_workflow submit_adversarial_review
      submit_security_review submit_visual_review submit_coworker_review
    ].freeze

    # Coworker-only tools that exist beside the shared catalog.
    COWORKER_SANITIZED_TOOLS = %w[
      list_repository_files read_repository_file search_repository_code
      read_backend_exception_events read_browser_error_events read_performance_log_events
    ].freeze

    COWORKER_LIFECYCLE_TOOLS = %w[
      discover_coworker_capabilities surrender_permission_lease request_permission_revocation
    ].freeze

    CORE_EXCEPTIONS = [
      ReviewedException.build(
        reason_code: "owner_permission_decision",
        explanation: "A coworker must not grant, deny, lease, or revoke its own permissions; the owner decides.",
        owner: "permissions", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: %i[coworker], tools: PERMISSION_TOOLS
      ),
      ReviewedException.build(
        reason_code: "workflow_run_bound_verdict",
        explanation: "Verdict/callback tools are bound to one reviewer or workflow run, not an interactive chat.",
        owner: "workflow-engine", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: CONTEXTS, tools: WORKFLOW_VERDICT_TOOLS
      ),
      ReviewedException.build(
        reason_code: "coworker_sanitized_surface",
        explanation: "Coworker-scoped repository reads and sanitized diagnostics, authorized by coworker grants.",
        owner: "coworkers", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: %i[planner coding local], tools: COWORKER_SANITIZED_TOOLS
      ),
      ReviewedException.build(
        reason_code: "coworker_identity_lifecycle",
        explanation: "Requests addressed to the coworker's owner have no subject outside a coworker chat.",
        owner: "coworkers", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: %i[planner coding local], tools: COWORKER_LIFECYCLE_TOOLS
      )
    ].freeze

    # Exceptions derived from the entry's own role gate (dedicated chat
    # modes). The role requirement is the registered reason; no name list.
    ROLE_EXCEPTIONS = {
      AgentRole::CHAT_CODING => ReviewedException.build(
        reason_code: "requires_coding_checkout",
        explanation: "Needs a Coding Mode checkout or runtime session.",
        owner: "coding-mode", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: %i[planner local coworker]
      ),
      AgentRole::CHAT_LOCAL => ReviewedException.build(
        reason_code: "requires_local_checkout",
        explanation: "Needs a Local Mode daemon workspace.",
        owner: "local-mode", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: %i[planner coding coworker]
      ),
      AgentRole::CHAT_EVALUATOR => ReviewedException.build(
        reason_code: "evaluator_run_bound",
        explanation: "Bound to the disposable scoped-event evaluator.",
        owner: "chat", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: CONTEXTS
      )
    }.freeze

    ROLE_CONTEXTS = {
      AgentRole::CHAT_CODING => :coding,
      AgentRole::CHAT_LOCAL => :local,
      AgentRole::CHAT_EVALUATOR => nil
    }.freeze

    class << self
      # The reviewed exception covering +entry+ (an ordinary chat registry
      # entry), or nil when it must be shared with coworkers.
      def core_exception_for(entry)
        by_name = CORE_EXCEPTIONS.find { |exception| exception.tools.include?(entry.tool_name) }
        return by_name if by_name

        role = ROLE_EXCEPTIONS.keys.find { |candidate| entry.required_roles.include?(candidate) }
        ROLE_EXCEPTIONS[role] if role
      end

      def exceptions = CORE_EXCEPTIONS + ROLE_EXCEPTIONS.values

      # Contexts in which a chat registry entry is discoverable.
      def chat_contexts_for(entry)
        roles = entry.required_roles
        return %i[planner coding local] if roles.empty? || roles.include?(AgentRole::CHAT_PLANNER)

        [ AgentRole::CHAT_CODING, AgentRole::CHAT_LOCAL ].filter_map do |role|
          ROLE_CONTEXTS.fetch(role) if roles.include?(role)
        end
      end

      def declared_absences(tool_name, entry)
        by_name = CORE_EXCEPTIONS.find { |exception| exception.tools.include?(tool_name) }
        return by_name.absent_from if by_name
        # A role gate absents the tool from every context but the roles it
        # names (the exception's own list covers only its primary role).
        entry && core_exception_for(entry) ? CONTEXTS - chat_contexts_for(entry) : []
      end

      # Resolved catalogs per context, from the registry.
      def catalogs
        chat = McpToolRegistry.entries(surface: :chat).group_by(&:tool_name)
        by_context = CONTEXTS.index_with { Set.new }
        chat.each do |name, entries|
          entries.flat_map { |entry| chat_contexts_for(entry) }.each { |context| by_context[context] << name }
        end
        by_context[:coworker] = McpToolRegistry.entries(surface: :coworker).map(&:tool_name).to_set
        by_context
      end

      # Differences not covered by a reviewed exception, in both directions:
      # a tool missing where it should be shared, an exception that no longer
      # matches reality, and a coworker-only tool nothing justifies.
      def report
        by_context = catalogs
        entries = McpToolRegistry.entries(surface: :chat).group_by(&:tool_name)
        names = by_context.values.reduce(:|)
        problems = []

        names.sort.each do |name|
          entry = entries[name]&.first
          allowed_absent = declared_absences(name, entry)
          actual_absent = CONTEXTS.reject { |context| by_context[context].include?(name) }
          unexplained = actual_absent - allowed_absent
          stale = allowed_absent - actual_absent
          problems << "#{name}: unexplained absence from #{unexplained.join(', ')}" if unexplained.any?
          problems << "#{name}: exception no longer applies to #{stale.join(', ')}" if stale.any?
        end

        registered = McpToolRegistry.entries.map(&:tool_name).to_set
        # Run-bound verdict tools live on the workflow surface, which may be
        # contributed by a plugin this registry does not load.
        CORE_EXCEPTIONS.reject { |exception| exception.absent_from == CONTEXTS }.flat_map(&:tools).uniq.each do |name|
          problems << "#{name}: exception names a tool that is not registered" unless registered.include?(name)
        end
        problems
      end
    end
  end
end
