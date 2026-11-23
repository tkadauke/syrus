module Permissions
  # Stable capability contracts for tools exposed to workflow agents. Registry
  # metadata still decides which role and Step may see a tool; these descriptors
  # describe the authority and effects of invoking it.
  class WorkflowActions
    Operation = Data.define(:capability, :name, :effects, :risk, :mutation)

    OBSERVATION = "syrus.workflow_observation@v1".freeze
    CONTROL = "syrus.workflow_control@v1".freeze
    RESULTS = "syrus.workflow_results@v1".freeze
    SOURCE = "syrus.workflow_source@v1".freeze
    RUNTIME = "syrus.workflow_runtime@v1".freeze

    READ = %i[local_read].freeze
    CONFIDENTIAL_READ = %i[confidential_read].freeze
    WRITE = %i[internal_write].freeze
    EXECUTE = %i[isolated_workspace_write isolated_execution].freeze

    OPERATIONS = {
      "read_live_state" => Operation.new(OBSERVATION, "read_live_state", READ, :low, false),
      "read_run_worker_health" => Operation.new(OBSERVATION, "read_worker_health", READ, :low, false),
      "read_preview_log" => Operation.new(OBSERVATION, "read_preview_log", READ, :low, false),
      "search_jobs" => Operation.new(SOURCE, "search_jobs", CONFIDENTIAL_READ, :low, false),
      "list_jobs" => Operation.new(SOURCE, "list_jobs", CONFIDENTIAL_READ, :low, false),
      "list_open_prs" => Operation.new(SOURCE, "list_open_pull_requests", %i[network_read], :low, false),
      "read_pr" => Operation.new(SOURCE, "read_pull_request", %i[network_read], :low, false),
      "list_ci_checks" => Operation.new(SOURCE, "list_ci_checks", %i[network_read], :low, false),
      "read_ci_log" => Operation.new(SOURCE, "read_ci_log", %i[network_read], :low, false),
      "list_open_issues" => Operation.new(SOURCE, "list_open_issues", %i[network_read], :low, false),
      "list_artifacts" => Operation.new(SOURCE, "list_artifacts", READ, :low, false),
      "read_artifact" => Operation.new(SOURCE, "read_artifact", CONFIDENTIAL_READ, :medium, false),
      "start_preview" => Operation.new(CONTROL, "start_preview", EXECUTE, :medium, true),
      "stop_preview" => Operation.new(CONTROL, "stop_preview", EXECUTE, :medium, true),
      "report_cannot_proceed" => Operation.new(RESULTS, "report_cannot_proceed", WRITE, :low, true),
      "report_main_concern" => Operation.new(RESULTS, "report_main_concern", WRITE, :low, true),
      "record_isolated_repro" => Operation.new(RESULTS, "record_isolated_repro", WRITE, :low, true),
      "submit_summary" => Operation.new(RESULTS, "submit_summary", WRITE, :low, true),
      "submit_test_plan" => Operation.new(RESULTS, "submit_test_plan", WRITE, :low, true),
      "submit_report" => Operation.new(RESULTS, "submit_report", WRITE, :low, true),
      "propose_job" => Operation.new(RESULTS, "propose_job", WRITE, :medium, true),
      "run_target_prepare" => Operation.new(CONTROL, "run_target_prepare", EXECUTE, :medium, true),
      "patch_workflow" => Operation.new(CONTROL, "patch_workflow", WRITE, :medium, true),
      "submit_visual_artifact" => Operation.new(RESULTS, "submit_visual_artifact", WRITE, :low, true),
      "runtime_inspect" => Operation.new(RUNTIME, "inspect", READ, :low, false),
      "runtime_wait" => Operation.new(RUNTIME, "wait", READ, :low, false),
      "runtime_acquire_control" => Operation.new(RUNTIME, "acquire_control", EXECUTE, :medium, true),
      "runtime_release_control" => Operation.new(RUNTIME, "release_control", EXECUTE, :medium, true),
      "runtime_input" => Operation.new(RUNTIME, "input", EXECUTE, :medium, true),
      "runtime_snapshot" => Operation.new(RUNTIME, "snapshot", EXECUTE, :medium, true),
      "runtime_capture_artifact" => Operation.new(RUNTIME, "capture_artifact", EXECUTE, :medium, true),
      "submit_job_metadata" => Operation.new(RESULTS, "submit_job_metadata", WRITE, :low, true),
      "submit_adversarial_review" => Operation.new(RESULTS, "submit_adversarial_review", WRITE, :medium, true),
      "submit_security_review" => Operation.new(RESULTS, "submit_security_review", WRITE, :medium, true),
      "submit_visual_review" => Operation.new(RESULTS, "submit_visual_review", WRITE, :medium, true)
    }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles:)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)
        default = operation.mutation ? :ask : :allow

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          presentation: CapabilityPresentation.for(capability: operation.capability, operation: identifier),
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { default },
          maximum_autonomy: operation.mutation ? :invocation : :permanent,
          authority_durations: operation.mutation ? %i[invocation] : CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain } },
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
