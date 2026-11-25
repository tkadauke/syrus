module Permissions
  # The intentional consequence classification of every core MCP tool.
  #
  # Each registered operation is exactly one of:
  #
  # - essential: consequence-free work an agent needs for research, planning,
  #   coordination, context management or bounded workflow execution. It is
  #   still evaluated and audited by the permission system, but no rule,
  #   preset, lease, generic fallback or authorization request can block it.
  # - gated by a barrier effect it declares (CapabilityDescriptor::BARRIER_EFFECTS).
  # - deniable for a named reason (CapabilityDescriptor::DENIABLE_REASONS) even
  #   though it declares no barrier effect.
  #
  # `default: allow` is not essential: an explicit deny rule overrides any
  # default. Internal persistence by itself is not a consequence barrier.
  #
  # Plugins classify their own operations where they register them
  # (`register_capability(essential: true)` / `deniable_reason:`); this table
  # covers core tools only, so no bundled plugin is referenced from core.
  # CapabilityRegistryValidator rejects any registration that is unclassified.
  module ConsequenceClassification
    CONTEXT = %w[
      ask_user_question suggest_next_step mark_goal_completed mark_goal_blocked
      rename_chat pin_chat unpin_chat set_bookmark update_pinned_context remove_pinned_context
    ].freeze

    # Withdrawing anything the agent itself put forward (a request, a card, a
    # wakeup, an undecided proposal) or narrowing its own authority.
    AUTHORITY_REDUCTION = %w[
      request_permission withdraw_pending_action cancel_authorization_request revoke_permission_lease cancel_wakeup
      delete_proposal
    ].freeze

    RESEARCH = %w[
      list_jobs search_jobs read_job list_epics read_epic repo_info list_repositories
      list_job_workflows read_workflow explain_stuck_job list_tags list_delivery_tracks
      resolve_delivery_policy list_ref_movement_actions read_ref_movement_status
      classify_pull_request read_provider_routing_rules explain_provider_routing search_syrus_docs
      list_repo_documents read_repo_document list_wakeups list_proposals list_pending_actions
      list_permissions explain_permission list_artifacts read_pr list_open_prs list_open_issues
      search_chats list_chats
      inspect_workflow_outcome_overrides
    ].freeze

    # Drafting a proposal only creates the operator's confirmation card; that
    # card is the decision that creates real work.
    WORKFLOW_OUTPUT = %w[
      report_cannot_proceed record_isolated_repro submit_summary
      submit_test_plan submit_report submit_job_metadata submit_adversarial_review
      submit_security_review submit_visual_review submit_visual_artifact submit_artifact
    ].freeze

    RUN_OBSERVATION = %w[
      read_live_state read_run_worker_health read_preview_log runtime_inspect runtime_wait
    ].freeze

    ESSENTIAL = {
      chat: (CONTEXT + AUTHORITY_REDUCTION + RESEARCH + %w[
        propose_job propose_epic_with_jobs propose_epic list_chat_media attach_repository detach_repository submit_artifact
        schedule_wakeup
        create_tag add_job_tag remove_job_tag
        runtime_inspect runtime_wait runtime_status runtime_list_sessions runtime_logs
        read_file list_files git_diff git_status
      ]).uniq.freeze,
      workflow: (WORKFLOW_OUTPUT + RUN_OBSERVATION + %w[
        propose_job list_jobs search_jobs read_pr list_ci_checks read_ci_log list_open_prs list_open_issues list_artifacts
        start_preview stop_preview run_target_prepare
      ]).uniq.freeze,
      agent_insight: %w[read_live_state read_run_worker_health].freeze,
      # A coworker has its own rules, separate from chat and from other
      # coworkers, but the same essentials: every chat essential it is offered
      # is essential for it too (see .essential?). These are the coworker-only
      # tools; repository reads stay limited to the repositories its grant
      # selects, which the tools themselves enforce.
      coworker: %w[
        discover_coworker_capabilities surrender_permission_lease request_permission_revocation
        list_repository_files read_repository_file search_repository_code
      ].freeze
    }.freeze

    # Core operations with no barrier effect that are nevertheless deniable.
    DENIABLE = {
      material_control: %w[
        approve_job unapprove_job close_job_successfully archive_epic move_epic_to_backlog
        update_job update_epic set_job_priority assign_job_to_epic remove_job_from_epic
        add_epic_dependency remove_epic_dependency add_job_dependency remove_job_dependency replace_job_dependency
        select_job_delivery_track mark_ci_repair_noop repair_provider_circuit_evidence
        retire_terminal_work_unit create_coding_job
        request_workflow_outcome_override
      ],
      privilege_change: %w[grant_permission deny_permission revoke_permission create_permission_lease apply_permission_preset],
      shared_state: %w[create_repo_document],
      external_ingestion: %w[ingest_pull_request],
      autonomy_expansion: %w[patch_workflow],
      confidential_cross_boundary: %w[get_job_diff read_run_transcript read_artifact read_chat_messages],
      instance_wide_observability: %w[
        admin_overview admin_stuck_jobs admin_queue_detail admin_list_processes admin_list_runs
        admin_list_users admin_version admin_mcp_tool_usage admin_github_app_installation_diagnostic
        admin_read_operational_logs read_worker_health read_metrics_diagnostics read_worker_occupancy
        read_workflow_timeline read_workflow_waterfall read_admission_diagnostics diagnose_run_queue
        read_queue inspect_provider_circuit read_backend_exception_events read_browser_error_events
        read_performance_log_events
      ],
      operator_scoping: %w[
        runtime_acquire_control runtime_release_control runtime_input runtime_snapshot runtime_capture_artifact
      ]
    }.transform_values(&:freeze).freeze

    DENIABLE_BY_TOOL = DENIABLE.flat_map { |reason, tools| tools.map { |tool| [ tool, reason ] } }.to_h.freeze

    class << self
      def essential?(tool_name, surface:)
        surface = surface.to_sym
        return true if ESSENTIAL.fetch(surface, []).include?(tool_name.to_s)

        # Coworkers share the chat essentials.
        surface == :coworker && ESSENTIAL.fetch(:chat).include?(tool_name.to_s)
      end

      def deniable_reason(tool_name, surface:)
        DENIABLE_BY_TOOL[tool_name.to_s]
      end

      # Stamps the classification onto a core registry descriptor. The table
      # is authoritative for core tools: whatever a family default declared,
      # an essential tool becomes essential on this surface and nothing else
      # does.
      def apply(descriptor, tool_name:, surface:)
        return descriptor unless descriptor

        essential = essential?(tool_name, surface:)
        reason = essential ? nil : deniable_reason(tool_name, surface:)
        reason = nil if !essential && descriptor.barrier_effects.any? && !DENIABLE_BY_TOOL.key?(tool_name.to_s)
        return descriptor if descriptor.essential? == essential && descriptor.deniable_reason == reason

        CapabilityDescriptor.new(**descriptor.to_h.merge(
          presentation: descriptor.presentation, essential:, deniable_reason: reason
        ))
      end
    end
  end
end
