module Permissions
  # Stable capability contracts for consequential admin repair, delivery, and
  # operational chat tools.
  #
  # Each tool maps to one operation under +syrus.admin_repair@v1+ (state
  # repair), +syrus.operations@v1+ (pausing, maintenance, cache and
  # installation housekeeping), or +syrus.delivery@v1+ (delivery tracks, ref
  # movement, and emergency landing). The mapping only supplies the evaluator
  # with classification and fingerprint data. Command-specific preconditions,
  # before/after repair snapshots, and fresh resource validation stay in the
  # tools and pending-action executors, which re-check the live record when
  # the approved invocation actually runs.
  #
  # Every operation is capped at exact-invocation authority: a repair or
  # delivery effect is never covered by a standing lease. Emergency landing is
  # additionally critical, irreversible, and has no preset that could widen it.
  class OperationalActions
    Operation = Data.define(:capability, :name, :effects, :risk)

    ADMIN_REPAIR = "syrus.admin_repair@v1".freeze
    OPERATIONS_CAPABILITY = "syrus.operations@v1".freeze
    DELIVERY = "syrus.delivery@v1".freeze

    STATE_CHANGE = %i[internal_write].freeze
    WORK_CONTROL = %i[internal_write operational].freeze
    DESTRUCTIVE_CONTROL = %i[internal_write operational destructive].freeze
    EXTERNAL_CONTROL = %i[internal_write operational external_write].freeze
    EMERGENCY = %i[internal_write operational external_write destructive irreversible].freeze

    OPERATIONS = {
      "force_fail_job" => Operation.new(ADMIN_REPAIR, "force_fail_job", DESTRUCTIVE_CONTROL, :high),
      "reconcile_job_state" => Operation.new(ADMIN_REPAIR, "reconcile_job_state", WORK_CONTROL, :medium),
      "force_state_transition" => Operation.new(ADMIN_REPAIR, "force_state_transition", DESTRUCTIVE_CONTROL, :critical),
      "cancel_stale_work" => Operation.new(ADMIN_REPAIR, "cancel_stale_work", DESTRUCTIVE_CONTROL, :high),
      "retire_terminal_work_unit" => Operation.new(ADMIN_REPAIR, "retire_terminal_work_unit", STATE_CHANGE, :medium),
      "reenqueue_work" => Operation.new(ADMIN_REPAIR, "reenqueue_work", WORK_CONTROL, :medium),
      "repair_queue_affinity" => Operation.new(ADMIN_REPAIR, "repair_queue_affinity", WORK_CONTROL, :medium),
      "admin_retry_step" => Operation.new(ADMIN_REPAIR, "retry_step", WORK_CONTROL, :medium),
      "admin_cleanup_workspace" => Operation.new(ADMIN_REPAIR, "cleanup_workspace", DESTRUCTIVE_CONTROL, :high),
      "admin_reap_stale_runs" => Operation.new(ADMIN_REPAIR, "reap_stale_runs", DESTRUCTIVE_CONTROL, :high),
      "admin_kill_process" => Operation.new(ADMIN_REPAIR, "kill_process", DESTRUCTIVE_CONTROL, :high),
      "manual_agentic_run" => Operation.new(ADMIN_REPAIR, "manual_agentic_run", WORK_CONTROL, :medium),
      "force_rebase" => Operation.new(ADMIN_REPAIR, "force_rebase", EXTERNAL_CONTROL, :high),
      "restack_epic" => Operation.new(ADMIN_REPAIR, "restack_epic", EXTERNAL_CONTROL, :high),
      "adopt_current_pr_head" => Operation.new(ADMIN_REPAIR, "adopt_current_pr_head", EXTERNAL_CONTROL, :high),
      "replace_pr_branch_with_workflow_output" => Operation.new(ADMIN_REPAIR, "replace_pr_branch", EXTERNAL_CONTROL, :critical),
      "retry_from_current_pr_branch" => Operation.new(ADMIN_REPAIR, "retry_from_pr_branch", WORK_CONTROL, :medium),
      "refresh_pr_checks" => Operation.new(ADMIN_REPAIR, "refresh_pr_checks", WORK_CONTROL, :low),
      "rerun_ci_repair" => Operation.new(ADMIN_REPAIR, "rerun_ci_repair", WORK_CONTROL, :medium),
      "mark_ci_repair_noop" => Operation.new(ADMIN_REPAIR, "mark_ci_repair_noop", STATE_CHANGE, :medium),
      "repair_provider_circuit_evidence" => Operation.new(ADMIN_REPAIR, "repair_provider_circuit_evidence", STATE_CHANGE, :medium),
      "clear_provider_circuit" => Operation.new(ADMIN_REPAIR, "clear_provider_circuit", WORK_CONTROL, :medium),
      "wake_provider_admission" => Operation.new(ADMIN_REPAIR, "wake_provider_admission", WORK_CONTROL, :low),
      "admin_maintenance_tasks" => Operation.new(OPERATIONS_CAPABILITY, "maintenance_tasks", WORK_CONTROL, :medium),
      "admin_pause_polling" => Operation.new(OPERATIONS_CAPABILITY, "pause_polling", WORK_CONTROL, :high),
      "admin_unpause_polling" => Operation.new(OPERATIONS_CAPABILITY, "unpause_polling", WORK_CONTROL, :medium),
      "admin_pause_runs" => Operation.new(OPERATIONS_CAPABILITY, "pause_runs", WORK_CONTROL, :high),
      "admin_unpause_runs" => Operation.new(OPERATIONS_CAPABILITY, "unpause_runs", WORK_CONTROL, :medium),
      "admin_pause_user_scheduling" => Operation.new(OPERATIONS_CAPABILITY, "pause_user_scheduling", WORK_CONTROL, :medium),
      "admin_unpause_user_scheduling" => Operation.new(OPERATIONS_CAPABILITY, "unpause_user_scheduling", WORK_CONTROL, :medium),
      "admin_clear_github_cache" => Operation.new(OPERATIONS_CAPABILITY, "clear_github_cache", WORK_CONTROL, :low),
      "admin_refresh_installations" => Operation.new(OPERATIONS_CAPABILITY, "refresh_installations", EXTERNAL_CONTROL, :medium),
      "select_job_delivery_track" => Operation.new(DELIVERY, "select_track", STATE_CHANGE, :medium),
      "dispatch_ref_movement_action" => Operation.new(DELIVERY, "dispatch_ref_movement", EXTERNAL_CONTROL, :high),
      "emergency_land" => Operation.new(DELIVERY, "emergency_land", EMERGENCY, :critical)
    }.freeze

    TARGET_KEYS = { "job_id" => "job_ids", "job_ids" => "job_ids" }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          presentation: CapabilityPresentation.for(capability: operation.capability, operation: identifier),
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { :ask },
          maximum_autonomy: :invocation,
          authority_durations: %i[invocation],
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:normalize_arguments)
        )
      end

      # Collapses singular/plural Job targets so one record and a one-element
      # bulk call fingerprint identically; every other argument is kept so the
      # approved invocation is exact.
      def normalize_arguments(arguments)
        source = arguments.to_h.transform_keys(&:to_s)
        normalized = source.except(*TARGET_KEYS.keys)
        ids = TARGET_KEYS.keys.flat_map { |key| Array(source[key]) }.compact.map { |id| Integer(id, exception: false) || id.to_s }
        normalized["job_ids"] = ids.uniq.sort_by(&:to_s) if ids.any?
        normalized.sort_by { |key, _| key }.to_h
      end
    end
  end
end
