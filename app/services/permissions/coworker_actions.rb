module Permissions
  # Canonical descriptors for core coworker tools. This table is the single
  # source of truth for their default policy: core grant defaults are derived
  # from it (+grant_default_policy+), and McpToolRegistry refuses to register a
  # coworker entry whose descriptor defaults to +allow+ without being provably
  # benign (see CoworkerDefaultPolicy). Plugins build theirs with +descriptor+.
  #
  # Capability and operation identifiers match the previous compatibility
  # descriptors so existing rules keep matching.
  class CoworkerActions
    Operation = Data.define(:family, :effects, :risk, :default, :benign_internal, :scope)

    READ = %i[local_read].freeze
    INTERNAL = %i[internal_write].freeze
    CONFIDENTIAL = %i[confidential_read].freeze

    def self.read(family) = Operation.new(family, READ, :low, :allow, nil, :none)
    def self.confidential(family) = Operation.new(family, CONFIDENTIAL, :medium, :ask, nil, :none)
    def self.benign(family, kind) = Operation.new(family, INTERNAL, :low, :allow, kind, :none)
    private_class_method :read, :confidential, :benign

    OPERATIONS = {
      # Read-only repository context. Attach/detach manage bounded read-only
      # checkouts; the owner's repository access and the grant's repository
      # scope are enforced by CoworkerRepositoryAccess, not by this default.
      "attach_repository" => benign("code.read", :context_binding),
      "detach_repository" => benign("code.read", :context_binding),
      "list_repository_files" => read("code.read"),
      "read_repository_file" => read("code.read"),
      "search_repository_code" => read("code.read"),
      "get_job_diff" => read("code.read"),
      "read_pr" => read("code.read"),
      # Owner-directed interaction and authority management.
      "ask_user_question" => benign("chat.message_owner", :owner_interaction),
      "suggest_next_step" => benign("chat.message_owner", :owner_interaction),
      "discover_coworker_capabilities" => read("chat.message_owner"),
      "request_permission" => benign("chat.message_owner", :owner_interaction),
      "surrender_permission_lease" => benign("chat.message_owner", :authority_reduction),
      "request_permission_revocation" => benign("chat.message_owner", :authority_reduction),
      # Jobs. Proposals stay pending until an operator confirms them.
      "list_jobs" => read("syrus.read_jobs"),
      "search_jobs" => read("syrus.read_jobs"),
      "read_job" => read("syrus.read_jobs"),
      "propose_job" => benign("syrus.propose_job", :draft_proposal),
      "propose_epic_with_jobs" => benign("syrus.propose_job", :draft_proposal),
      # Cross-chat reads can contain anything another chat saw.
      "list_chats" => confidential("chats.read_shared"),
      "search_chats" => confidential("chats.read_shared"),
      "read_chat_messages" => confidential("chats.read_shared"),
      # Operational telemetry and logs.
      "admin_read_operational_logs" => confidential("ops.read_logs"),
      "read_worker_health" => confidential("ops.read_logs"),
      "read_backend_exception_events" => confidential("ops.read_logs"),
      "read_browser_error_events" => confidential("ops.read_logs"),
      "read_performance_log_events" => confidential("ops.read_logs"),
      "read_metrics_diagnostics" => confidential("ops.read_logs"),
      "read_worker_occupancy" => confidential("ops.read_logs"),
      "read_workflow_timeline" => confidential("ops.read_logs"),
      "read_workflow_waterfall" => confidential("ops.read_logs"),
      "read_admission_diagnostics" => confidential("ops.read_logs"),
      "diagnose_run_queue" => confidential("ops.read_logs")
    }.freeze

    class << self
      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles: CoworkerDefaultPolicy::ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        descriptor(tool_name: tool_name, family: operation.family, effects: operation.effects, risk: operation.risk,
          default: operation.default, benign_internal: operation.benign_internal, roles: required_roles)
      end

      # The grant default implied by every non-ungated tool in a family.
      def grant_default_policy(family, ungated: [])
        policies = OPERATIONS.select { |name, operation| operation.family == family.to_s && !ungated.include?(name) }
          .values.map(&:default)
        CoworkerDefaultPolicy.grant_policy_for(policies)
      end

      # Builds a coworker descriptor and validates the default against the
      # shared safety rule, so a new tool cannot silently inherit +allow+.
      def descriptor(tool_name:, family:, effects:, risk:, default:, roles: CoworkerDefaultPolicy::ROLES,
        benign_internal: nil, maximum_autonomy: nil, durations: nil)
        family = family.to_s
        operation = "#{family}/#{tool_name.to_s.tr('/', '.').gsub(/[^a-zA-Z0-9_.-]/, '_').downcase}@v1"
        effects = Array(effects)
        # Pure reads keep the historical permanent ceiling; any write stays per-invocation.
        maximum_autonomy ||= effects.all? { |effect| %i[local_read confidential_read].include?(effect) } ? :permanent : :invocation
        durations ||= maximum_autonomy == :permanent ? CapabilityDescriptor::AUTHORITY_DURATIONS : [ :invocation ]

        CoworkerDefaultPolicy.validate!(CapabilityDescriptor.new(
          capability: "#{family}@v1",
          operation: operation,
          effects: effects,
          risk: risk,
          requestable_roles: roles,
          defaults: Array(roles).index_with { default },
          maximum_autonomy: maximum_autonomy,
          authority_durations: durations,
          resource_scope: { type: :none },
          benign_internal: benign_internal,
          classifier: ->(_arguments) { { operation: operation, effects: effects, risk: risk, confidence: :certain } },
          fingerprint_normalizer: ->(arguments) { deep_normalize(arguments) },
          redactor: ->(arguments) { CapabilityDescriptorAdapter.send(:deep_redact, arguments) }
        ))
      end

      private

      def deep_normalize(value) = CapabilityDescriptorAdapter.send(:deep_normalize, value)
    end
  end
end
