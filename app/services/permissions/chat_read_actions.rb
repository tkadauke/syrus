module Permissions
  # Stable capability contracts for read-only chat tools. Registry metadata
  # continues to own discovery tiers, feature gates, admin checks, and role
  # restrictions; these descriptors group the reads by the domain they expose.
  class ChatReadActions
    Operation = Data.define(:capability, :name)

    JOBS = "syrus.job_reads@v1".freeze
    EPICS = "syrus.epic_reads@v1".freeze
    CHATS = "syrus.chat_reads@v1".freeze
    WORKFLOWS = "syrus.workflow_reads@v1".freeze
    QUEUES = "syrus.queue_reads@v1".freeze
    DOCUMENTS = "syrus.document_reads@v1".freeze
    REPOSITORIES = "syrus.repository_reads@v1".freeze
    RUNTIME = "syrus.runtime_status@v1".freeze
    LOCAL = "syrus.local_reads@v1".freeze
    ADMIN = "syrus.admin_diagnostics@v1".freeze

    OPERATIONS = {
      "list_proposals" => Operation.new(CHATS, "list_proposals"),
      "list_pending_actions" => Operation.new(CHATS, "list_pending_actions"),
      "list_jobs" => Operation.new(JOBS, "list"),
      "list_open_agent_questions" => Operation.new(JOBS, "list_open_agent_questions"),
      "search_jobs" => Operation.new(JOBS, "search"),
      "read_job" => Operation.new(JOBS, "read"),
      "read_provider_routing_rules" => Operation.new(JOBS, "read_provider_routing_rules"),
      "explain_provider_routing" => Operation.new(JOBS, "explain_provider_routing"),
      "list_epics" => Operation.new(EPICS, "list"),
      "read_epic" => Operation.new(EPICS, "read"),
      "repo_info" => Operation.new(REPOSITORIES, "info"),
      "runtime_list_sessions" => Operation.new(RUNTIME, "list_sessions"),
      "runtime_status" => Operation.new(RUNTIME, "status"),
      "runtime_inspect" => Operation.new(RUNTIME, "inspect"),
      "runtime_wait" => Operation.new(RUNTIME, "wait"),
      "runtime_logs" => Operation.new(RUNTIME, "logs"),
      "admin_overview" => Operation.new(ADMIN, "overview"),
      "admin_stuck_jobs" => Operation.new(ADMIN, "stuck_jobs"),
      "admin_queue_detail" => Operation.new(ADMIN, "queue_detail"),
      "admin_list_processes" => Operation.new(ADMIN, "list_processes"),
      "admin_list_runs" => Operation.new(ADMIN, "list_runs"),
      "admin_list_users" => Operation.new(ADMIN, "list_users"),
      "admin_version" => Operation.new(ADMIN, "version"),
      "read_worker_health" => Operation.new(ADMIN, "read_worker_health"),
      "read_metrics_diagnostics" => Operation.new(ADMIN, "read_metrics"),
      "read_worker_occupancy" => Operation.new(ADMIN, "read_worker_occupancy"),
      "read_workflow_timeline" => Operation.new(ADMIN, "read_workflow_timeline"),
      "read_workflow_waterfall" => Operation.new(ADMIN, "read_workflow_waterfall"),
      "read_admission_diagnostics" => Operation.new(ADMIN, "read_admission"),
      "diagnose_run_queue" => Operation.new(ADMIN, "diagnose_run_queue"),
      "admin_read_operational_logs" => Operation.new(ADMIN, "read_operational_logs"),
      "admin_mcp_tool_usage" => Operation.new(ADMIN, "mcp_tool_usage"),
      "admin_github_app_installation_diagnostic" => Operation.new(ADMIN, "github_app_installation"),
      "inspect_provider_circuit" => Operation.new(ADMIN, "inspect_provider_circuit"),
      "read_file" => Operation.new(LOCAL, "read_file"),
      "list_files" => Operation.new(LOCAL, "list_files"),
      "git_diff" => Operation.new(LOCAL, "git_diff"),
      "git_status" => Operation.new(LOCAL, "git_status"),
      "list_chats" => Operation.new(CHATS, "list"),
      "list_repositories" => Operation.new(REPOSITORIES, "list"),
      "list_job_workflows" => Operation.new(WORKFLOWS, "list_for_job"),
      "read_workflow" => Operation.new(WORKFLOWS, "read"),
      "list_artifacts" => Operation.new(WORKFLOWS, "list_artifacts"),
      "explain_stuck_job" => Operation.new(JOBS, "explain_stuck"),
      "list_tags" => Operation.new(JOBS, "list_tags"),
      "list_repo_documents" => Operation.new(DOCUMENTS, "list_repository_documents"),
      "read_repo_document" => Operation.new(DOCUMENTS, "read_repository_document"),
      "list_wakeups" => Operation.new(CHATS, "list_wakeups"),
      "read_queue" => Operation.new(QUEUES, "read"),
      "search_syrus_docs" => Operation.new(DOCUMENTS, "search_syrus_docs"),
      "list_delivery_tracks" => Operation.new(JOBS, "list_delivery_tracks"),
      "resolve_delivery_policy" => Operation.new(JOBS, "resolve_delivery_policy"),
      "list_ref_movement_actions" => Operation.new(REPOSITORIES, "list_ref_movement_actions"),
      "read_ref_movement_status" => Operation.new(REPOSITORIES, "read_ref_movement_status"),
      "classify_pull_request" => Operation.new(REPOSITORIES, "classify_pull_request")
    }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          presentation: CapabilityPresentation.for(capability: operation.capability, operation: identifier),
          effects: %i[local_read],
          risk: :low,
          requestable_roles: roles,
          defaults: roles.index_with { :allow },
          maximum_autonomy: :permanent,
          authority_durations: CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: identifier, effects: %i[local_read], risk: :low, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: ->(arguments) { ToolPayloadRedactor.redact(normalize_arguments(arguments)) }
        )
      end

      def normalize_arguments(arguments)
        arguments.to_h.transform_keys(&:to_s).reject { |_key, value| value.nil? }.sort_by { |key, _| key }.to_h
      end
    end
  end
end
