module Admin
  class CapabilitySurfaceRegistry
    SurfaceDecision = Data.define(:surface, :status, :reason, :sources) do
      def exposed? = status == "exposed"

      def to_h
        {
          surface: surface,
          status: status,
          reason: reason,
          sources: sources
        }
      end
    end

    Capability = Data.define(:key, :sources, :decisions) do
      def decision_for(surface)
        decisions.fetch(surface.to_sym)
      end

      def to_h
        {
          key: key,
          sources: sources,
          surfaces: decisions.transform_values(&:to_h)
        }
      end
    end

    SURFACES = %i[user_api admin_api cli mcp].freeze

    API_CLI_PENDING_ACTION_REASON = "PendingAction execution is currently chat-confirmation backed; direct API and CLI invocation decisions are tracked separately from the implementation class.".freeze
    MCP_PENDING_ACTION_REASON = "This PendingAction has no static McpToolRegistry exposure yet; any dynamic or future MCP exposure must be registered explicitly.".freeze
    WORKFLOW_MCP_REASON = "Workflow-agent capability only; no user API, admin API, or CLI invocation contract is registered.".freeze

    PENDING_ACTION_CAPABILITIES = %w[
      admin_cleanup_workspace
      admin_clear_github_cache
      admin_kill_process
      admin_maintenance_task
      admin_pause_polling
      admin_pause_runs
      admin_pause_user_scheduling
      admin_reap_stale_runs
      admin_refresh_installations
      admin_retry_step
      admin_unpause_polling
      admin_unpause_runs
      admin_unpause_user_scheduling
      adopt_current_pr_head
      approve_job
      archive_epic
      cancel_job
      cancel_stale_work
      check_job_mergeability
      clear_provider_circuit
      close_job_successfully
      complete_implement_step
      create_repo_document
      delegate_issue
      delete_design_doc
      delete_repo_document
      emergency_land
      fire_scheduled_task_now
      force_fail_job
      force_landing_recheck
      force_rebase
      force_state_transition
      local_tool_call
      manual_agentic_run
      mark_ci_repair_noop
      override_landing_blocker_once
      pause_landing_queue
      poll_job_feedback
      rebase_job
      reconcile_job_state
      reenqueue_work
      reopen_epic_and_attach_job
      reopen_job
      repair_provider_circuit_evidence
      replace_pr_branch_with_workflow_output
      rerun_ci_repair
      restack_epic
      resume_landing_queue
      retry_from_current_pr_branch
      retry_job
      run_visual_review
      schedule_recurring
      submit_chat_feedback
      submit_coding_changes
      unapprove_job
      wake_landing_queue
      wake_provider_admission
    ].freeze

    WORKFLOW_MCP_CAPABILITIES = %w[
      patch_workflow
      run_target_prepare
      submit_adversarial_review
      submit_artifact
      submit_job_metadata
      submit_report
      submit_summary
      submit_test_plan
      submit_visual_artifact
      submit_visual_review
    ].freeze

    EXPLICIT_SURFACE_DECISIONS = begin
      decisions = {}

      PENDING_ACTION_CAPABILITIES.each do |key|
        decisions[key] = {
          user_api: { status: "not_exposed", reason: API_CLI_PENDING_ACTION_REASON },
          admin_api: { status: "not_exposed", reason: API_CLI_PENDING_ACTION_REASON },
          cli: { status: "not_exposed", reason: API_CLI_PENDING_ACTION_REASON },
          mcp: { status: "not_exposed", reason: MCP_PENDING_ACTION_REASON }
        }
      end

      WORKFLOW_MCP_CAPABILITIES.each do |key|
        decisions[key] ||= {}
        %i[user_api admin_api cli].each do |surface|
          decisions[key][surface] = { status: "not_exposed", reason: WORKFLOW_MCP_REASON }
        end
      end

      decisions.transform_values(&:freeze).freeze
    end

    class << self
      def capabilities(**kwargs)
        new(**kwargs).capabilities
      end

      def coverage_gaps(**kwargs)
        new(**kwargs).coverage_gaps
      end
    end

    def initialize(mcp_entries: McpToolRegistry.entries, pending_action_classes: nil, explicit_decisions: EXPLICIT_SURFACE_DECISIONS)
      @mcp_entries = mcp_entries
      @pending_action_classes = pending_action_classes
      @explicit_decisions = explicit_decisions.deep_symbolize_keys
    end

    def capabilities
      capability_keys.map do |key|
        Capability.new(
          key: key,
          sources: sources_for(key),
          decisions: decisions_for(key)
        )
      end
    end

    def coverage_gaps
      capabilities.flat_map do |capability|
        SURFACES.filter_map do |surface|
          decision = capability.decisions[surface]
          next if decision && decision.reason.present?

          {
            capability: capability.key,
            surface: surface,
            sources: capability.sources
          }
        end
      end
    end

    private

    attr_reader :mcp_entries, :pending_action_classes, :explicit_decisions

    def capability_keys
      (mcp_capability_sources.keys + pending_action_sources.keys).uniq.sort
    end

    def sources_for(key)
      (mcp_capability_sources.fetch(key, []) + pending_action_sources.fetch(key, [])).sort_by { |source| [ source.fetch(:source), source.fetch(:name) ] }
    end

    def decisions_for(key)
      SURFACES.index_with do |surface|
        exposed = exposed_sources_for(key, surface)
        if exposed.any?
          SurfaceDecision.new(surface: surface, status: "exposed", reason: "Registered by #{exposed.map { |source| source.fetch(:source) }.uniq.to_sentence}.", sources: exposed)
        elsif (decision = explicit_decisions.dig(key.to_sym, surface))
          SurfaceDecision.new(surface: surface, status: decision.fetch(:status).to_s, reason: decision.fetch(:reason).to_s, sources: [])
        end
      end
    end

    def exposed_sources_for(key, surface)
      return mcp_capability_sources.fetch(key, []) if surface == :mcp

      []
    end

    def mcp_capability_sources
      @mcp_capability_sources ||= mcp_entries.each_with_object({}) do |entry, index|
        next unless entry.capability

        key = entry.capability.to_s
        index[key] ||= []
        index[key] << {
          source: "mcp",
          name: entry.tool_name,
          surface: entry.surface,
          mutation: entry.mutation,
          admin_only: entry.admin_only
        }
      end
    end

    def pending_action_sources
      @pending_action_sources ||= resolved_pending_action_classes.each_with_object({}) do |klass, index|
        key = klass.action_key.to_s
        index[key] ||= []
        index[key] << {
          source: "pending_action",
          name: klass.name,
          admin_only: klass.admin_only?
        }
      end
    end

    def resolved_pending_action_classes
      return pending_action_classes if pending_action_classes

      load_pending_action_classes
      PendingActions::REGISTRY.values
    end

    def load_pending_action_classes
      pending_action_paths.each do |path|
        require_dependency path
      end
    end

    def pending_action_paths
      Rails.root.glob("app/services/pending_actions/*.rb")
        .concat(Rails.root.glob("plugins/*/app/services/pending_actions/*.rb"))
        .reject { |path| path.basename.to_s == "base.rb" }
        .sort
    end
  end
end
