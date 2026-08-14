class Step
  module Kind
    # Failure policy symbols used by StepDispatcher#fail!:
    #   :advance        — step advances past failure (grader: siblings still run)
    #   :loop_iteration — drives the retry_until loop counter (grader_collect, grade)
    #   :default        — workflow fails unless a try-branch handles it
    #
    # reconcile_strategy maps to a RunCompletionReconciler method suffix:
    #   nil           — not reconcilable (most steps)
    #   :pr_open      → reconcile_pr_open
    #   :auto_merge   → reconcile_auto_merge
    #   :merge_train_land → reconcile_merge_train_land
    #
    # skip_if_artifact: artifact key whose presence causes StepDispatcher to
    #   skip-and-succeed this queued step without running it.
    #
    # triggers_auto_approval: true for the terminal grader step kinds that
    #   fire AutoApprovalRule after a successful grade.
    #
    # required_mcp_tools: MCP tools the agent MUST call during this step.
    Entry = Data.define(:kind, :handler, :label, :style, :agentic,
                        :required_mcp_tools, :fail_policy, :reconcile_strategy,
                        :skip_if_artifact, :triggers_auto_approval, :repair_semantics,
                        :resource_profile_step_kinds, :resource_profile_grader_name_key,
                        :resource_profile_default_overrides) do
      def initialize(kind:, handler:, label:, style:, agentic:,
                     required_mcp_tools: [],
                     fail_policy: :default,
                     reconcile_strategy: nil,
                     skip_if_artifact: nil,
                     triggers_auto_approval: false,
                     repair_semantics: nil,
                     resource_profile_step_kinds: nil,
                     resource_profile_grader_name_key: nil,
                     resource_profile_default_overrides: nil)
        repair_semantics ||= agentic ? :agentic : :operator_review
        resource_profile_step_kinds ||= [ kind ]
        super
      end

      def handler_class
        "Steps::#{handler}".constantize
      end

      def deterministic_idempotent_repair?
        repair_semantics == :deterministic_idempotent
      end

      def publication_repair?
        repair_semantics == :publication
      end

      def rebuild_repair?
        repair_semantics == :rebuild
      end

      def resource_profile_keys_for(step = nil)
        resource_profile_step_kinds.map do |profile_step_kind|
          grader_name =
            if profile_step_kind == kind && resource_profile_grader_name_key.present?
              step&.details.to_h[resource_profile_grader_name_key].to_s
            elsif profile_step_kind == kind
              ""
            else
              nil
            end
          [ profile_step_kind, grader_name ]
        end
      end

      def resource_profile_defaults
        return nil if resource_profile_default_overrides.blank?

        WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.merge(resource_profile_default_overrides)
      end
    end

    ENTRIES = [
      Entry.new(kind: "prepare",            handler: "Prepare",            label: "Prepare workspace",         style: "bg-gray-100 text-gray-700",   agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "implement",          handler: "Implement",          label: "Implement",                  style: "bg-blue-100 text-blue-700",   agentic: true),
      Entry.new(kind: "adversarial_review", handler: "AdversarialReview",  label: "Adversarial review",        style: "bg-rose-100 text-rose-700",   agentic: true,
                required_mcp_tools: %w[submit_adversarial_review]),
      Entry.new(kind: "visual_review",      handler: "VisualReview",      label: "Visual review",             style: "bg-pink-100 text-pink-700",   agentic: true,
                required_mcp_tools: %w[submit_visual_review]),
      Entry.new(kind: "summarize",          handler: "Summarize",          label: "Summarize",                  style: "bg-indigo-100 text-indigo-700", agentic: true,
                required_mcp_tools: %w[submit_summary]),
      Entry.new(kind: "test_plan",          handler: "TestPlan",           label: "Test plan",                  style: "bg-sky-100 text-sky-700",     agentic: true,
                required_mcp_tools: %w[submit_test_plan],
                skip_if_artifact: "test_plan"),
      Entry.new(kind: "pr_open",            handler: "PrOpen",             label: "Open PR",                    style: "bg-emerald-100 text-emerald-700", agentic: false,
                repair_semantics: :publication,
                reconcile_strategy: :pr_open),
      Entry.new(kind: "respond",            handler: "Respond",            label: "Address feedback",           style: "bg-cyan-100 text-cyan-700",   agentic: true),
      Entry.new(kind: "summarize_amend",    handler: "SummarizeAmend",     label: "Summarize",                  style: "bg-indigo-100 text-indigo-700", agentic: true,
                required_mcp_tools: %w[submit_summary]),
      Entry.new(kind: "refresh_job_metadata", handler: "RefreshJobMetadata", label: "Refresh metadata",          style: "bg-purple-100 text-purple-700", agentic: true,
                required_mcp_tools: %w[submit_job_metadata]),
      Entry.new(kind: "push",               handler: "Push",               label: "Push",                       style: "bg-emerald-100 text-emerald-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "push_agent_rebase",  handler: "PushAgentRebase",    label: "Resolve push rebase",       style: "bg-teal-100 text-teal-700",   agentic: true),
      Entry.new(kind: "push_after_rebase",  handler: "PushAfterRebase",    label: "Push rebased branch",       style: "bg-emerald-100 text-emerald-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "analyze_and_fix",    handler: "AnalyzeAndFix",      label: "Fix CI failures",            style: "bg-red-100 text-red-700",     agentic: true),
      Entry.new(kind: "auto_rebase",        handler: "AutoRebase",         label: "Auto-rebase",                style: "bg-teal-100 text-teal-700",   agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "agent_rebase",       handler: "AgentRebase",        label: "Agent rebase",               style: "bg-teal-100 text-teal-700",   agentic: true),
      Entry.new(kind: "force_push",         handler: "ForcePush",          label: "Force-push",                 style: "bg-amber-100 text-amber-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "stack_auto_rebase",  handler: "StackAutoRebase",    label: "Stack auto-rebase",         style: "bg-teal-100 text-teal-700",   agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "stack_agent_rebase", handler: "StackAgentRebase",   label: "Stack agent rebase",        style: "bg-teal-100 text-teal-700",   agentic: true),
      Entry.new(kind: "stack_force_push",   handler: "StackForcePush",     label: "Stack force-push",          style: "bg-amber-100 text-amber-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "mergeability_preflight", handler: "MergeabilityPreflight", label: "Mergeability preflight", style: "bg-sky-100 text-sky-700", agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "speculative_landing_build", handler: "SpeculativeLandingBuild", label: "Build speculative landing", style: "bg-emerald-100 text-emerald-700", agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "grade",              handler: "Grade",              label: "Grade",                      style: "bg-violet-100 text-violet-700", agentic: false,
                fail_policy: :loop_iteration,
                repair_semantics: :deterministic_idempotent,
                triggers_auto_approval: true),
      Entry.new(kind: "grader",             handler: "Grader",             label: "Grader",                     style: "bg-violet-100 text-violet-700", agentic: false,
                fail_policy: :advance,
                repair_semantics: :deterministic_idempotent,
                resource_profile_grader_name_key: "name"),
      Entry.new(kind: "grader_fanout",      handler: "GraderFanout",       label: "Plan graders",               style: "bg-violet-100 text-violet-700", agentic: false,
                repair_semantics: :deterministic_idempotent,
                resource_profile_step_kinds: %w[grader_fanout grader],
                resource_profile_default_overrides: {
                  duration_seconds: 60,
                  process_attributed_duration_seconds: 60,
                  process_attributed_cpu_percent: 5.0,
                  cpu_pressure: 5.0,
                  io_pressure: 5.0,
                  memory_used_percent: 20.0,
                  timeout_rate: 0.0,
                  failure_rate: 0.0
                }),
      Entry.new(kind: "grader_collect",     handler: "GraderCollect",      label: "Aggregate graders",          style: "bg-violet-100 text-violet-700", agentic: false,
                fail_policy: :loop_iteration,
                repair_semantics: :deterministic_idempotent,
                triggers_auto_approval: true),
      Entry.new(kind: "apply_suggestions",  handler: "ApplySuggestions",   label: "Apply suggestions",         style: "bg-lime-100 text-lime-700",   agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "landing_fix",        handler: "LandingFix",         label: "Final fix",                  style: "bg-blue-100 text-blue-700",   agentic: true),
      Entry.new(kind: "coding_handoff_fix", handler: "CodingHandoffFix",   label: "Repair handoff",            style: "bg-blue-100 text-blue-700",   agentic: true),
      Entry.new(kind: "auto_merge",         handler: "AutoMerge",          label: "Auto-merge",                 style: "bg-green-100 text-green-700", agentic: false,
                repair_semantics: :publication,
                reconcile_strategy: :auto_merge),
      Entry.new(kind: "external_pr_merge",  handler: "ExternalPrMerge",    label: "Merge external PR",          style: "bg-green-100 text-green-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "merge_train_assemble", handler: "MergeTrainAssemble", label: "Assemble train",          style: "bg-green-100 text-green-800", agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "merge_train_build",  handler: "MergeTrainBuild",    label: "Build integration branch",  style: "bg-green-100 text-green-800", agentic: true,
                repair_semantics: :rebuild),
      Entry.new(kind: "merge_train_reconcile", handler: "MergeTrainReconcile", label: "Reconcile train",       style: "bg-teal-100 text-teal-700",   agentic: true),
      Entry.new(kind: "merge_train_land",   handler: "MergeTrainLand",     label: "Land Epic",                  style: "bg-green-100 text-green-800", agentic: false,
                repair_semantics: :publication,
                reconcile_strategy: :merge_train_land),
      Entry.new(kind: "merge_train_rebase", handler: "MergeTrainRebase",   label: "Rebase integration branch", style: "bg-teal-100 text-teal-700",   agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "merge_train_land_after_rebase", handler: "MergeTrainLandAfterRebase", label: "Land Epic after rebase", style: "bg-green-100 text-green-800", agentic: false,
                repair_semantics: :publication,
                reconcile_strategy: :merge_train_land),
      Entry.new(kind: "manual",             handler: "Manual",             label: "Manual",                     style: "bg-gray-100 text-gray-700",   agentic: true),
      Entry.new(kind: "manual_agentic_run", handler: "ManualAgenticRun",   label: "Manual agentic run",         style: "bg-fuchsia-100 text-fuchsia-700", agentic: true),
      Entry.new(kind: "coverage_analyze",   handler: "CoverageAnalyze",    label: "Analyze coverage",           style: "bg-yellow-100 text-yellow-700", agentic: false,
                repair_semantics: :deterministic_idempotent),
      Entry.new(kind: "coverage_pr_comment", handler: "CoveragePrComment", label: "Post coverage comment",     style: "bg-yellow-100 text-yellow-700", agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "agent_insight_run",  handler: "AgentInsightRun",   label: "Agent insight analysis",    style: "bg-amber-100 text-amber-700",   agentic: true),
      Entry.new(kind: "auto_close",         handler: "AutoClose",          label: "Auto-close",                style: "bg-gray-100 text-gray-500",     agentic: false,
                repair_semantics: :publication),
      Entry.new(kind: "preflight_grader",         handler: "PreflightGrader",         label: "Preflight grader",         style: "bg-gray-100 text-gray-500",     agentic: false,
                fail_policy: :advance,
                repair_semantics: :deterministic_idempotent,
                resource_profile_grader_name_key: "name"),
      Entry.new(kind: "preflight_grader_fanout",  handler: "PreflightGraderFanout",  label: "Plan preflight graders",   style: "bg-violet-100 text-violet-700", agentic: false,
                repair_semantics: :deterministic_idempotent,
                resource_profile_step_kinds: %w[preflight_grader_fanout preflight_grader],
                resource_profile_default_overrides: {
                  duration_seconds: 60,
                  process_attributed_duration_seconds: 60,
                  process_attributed_cpu_percent: 5.0,
                  cpu_pressure: 5.0,
                  io_pressure: 5.0,
                  memory_used_percent: 20.0,
                  timeout_rate: 0.0,
                  failure_rate: 0.0
                }),
      Entry.new(kind: "preflight_grader_collect", handler: "PreflightGraderCollect", label: "Preflight grader check",   style: "bg-violet-100 text-violet-700", agentic: false,
                repair_semantics: :deterministic_idempotent)
    ].freeze

    BY_KIND = ENTRIES.index_by(&:kind).freeze

    module_function

    def values
      BY_KIND.keys.freeze
    end

    def agentic_values
      ENTRIES.select(&:agentic).map(&:kind).freeze
    end

    def fetch(kind)
      BY_KIND.fetch(kind.to_s) do
        raise ArgumentError, "unknown step kind=#{kind.inspect}"
      end
    end

    def handler_for(kind)
      fetch(kind).handler_class
    end

    def registry
      BY_KIND.transform_values(&:handler).freeze
    end

    def label_for(kind)
      fetch(kind).label
    rescue ArgumentError
      kind.to_s.humanize
    end

    def style_for(kind)
      fetch(kind).style
    rescue ArgumentError
      nil
    end
  end
end
