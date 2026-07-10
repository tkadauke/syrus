class Step
  module Kind
    Entry = Data.define(:kind, :handler, :label, :style, :agentic) do
      def handler_class
        "Steps::#{handler}".constantize
      end
    end

    ENTRIES = [
      Entry.new(kind: "prepare", handler: "Prepare", label: "Prepare workspace", style: "bg-gray-100 text-gray-700", agentic: false),
      Entry.new(kind: "implement", handler: "Implement", label: "Implement", style: "bg-blue-100 text-blue-700", agentic: true),
      Entry.new(kind: "adversarial_review", handler: "AdversarialReview", label: "Adversarial review", style: "bg-rose-100 text-rose-700", agentic: true),
      Entry.new(kind: "summarize", handler: "Summarize", label: "Summarize", style: "bg-indigo-100 text-indigo-700", agentic: true),
      Entry.new(kind: "test_plan", handler: "TestPlan", label: "Test plan", style: "bg-sky-100 text-sky-700", agentic: true),
      Entry.new(kind: "pr_open", handler: "PrOpen", label: "Open PR", style: "bg-emerald-100 text-emerald-700", agentic: false),
      Entry.new(kind: "respond", handler: "Respond", label: "Address feedback", style: "bg-cyan-100 text-cyan-700", agentic: true),
      Entry.new(kind: "summarize_amend", handler: "SummarizeAmend", label: "Summarize", style: "bg-indigo-100 text-indigo-700", agentic: true),
      Entry.new(kind: "push", handler: "Push", label: "Push", style: "bg-emerald-100 text-emerald-700", agentic: false),
      Entry.new(kind: "push_agent_rebase", handler: "PushAgentRebase", label: "Resolve push rebase", style: "bg-teal-100 text-teal-700", agentic: true),
      Entry.new(kind: "push_after_rebase", handler: "PushAfterRebase", label: "Push rebased branch", style: "bg-emerald-100 text-emerald-700", agentic: false),
      Entry.new(kind: "analyze_and_fix", handler: "AnalyzeAndFix", label: "Fix CI failures", style: "bg-red-100 text-red-700", agentic: true),
      Entry.new(kind: "auto_rebase", handler: "AutoRebase", label: "Auto-rebase", style: "bg-teal-100 text-teal-700", agentic: false),
      Entry.new(kind: "agent_rebase", handler: "AgentRebase", label: "Agent rebase", style: "bg-teal-100 text-teal-700", agentic: true),
      Entry.new(kind: "force_push", handler: "ForcePush", label: "Force-push", style: "bg-amber-100 text-amber-700", agentic: false),
      Entry.new(kind: "stack_auto_rebase", handler: "StackAutoRebase", label: "Stack auto-rebase", style: "bg-teal-100 text-teal-700", agentic: false),
      Entry.new(kind: "stack_agent_rebase", handler: "StackAgentRebase", label: "Stack agent rebase", style: "bg-teal-100 text-teal-700", agentic: true),
      Entry.new(kind: "stack_force_push", handler: "StackForcePush", label: "Stack force-push", style: "bg-amber-100 text-amber-700", agentic: false),
      Entry.new(kind: "mergeability_preflight", handler: "MergeabilityPreflight", label: "Mergeability preflight", style: "bg-sky-100 text-sky-700", agentic: false),
      Entry.new(kind: "grade", handler: "Grade", label: "Grade", style: "bg-violet-100 text-violet-700", agentic: false),
      Entry.new(kind: "grader", handler: "Grader", label: "Grader", style: "bg-violet-100 text-violet-700", agentic: false),
      Entry.new(kind: "grader_fanout", handler: "GraderFanout", label: "Plan graders", style: "bg-violet-100 text-violet-700", agentic: false),
      Entry.new(kind: "grader_collect", handler: "GraderCollect", label: "Aggregate graders", style: "bg-violet-100 text-violet-700", agentic: false),
      Entry.new(kind: "apply_suggestions", handler: "ApplySuggestions", label: "Apply suggestions", style: "bg-lime-100 text-lime-700", agentic: false),
      Entry.new(kind: "landing_fix", handler: "LandingFix", label: "Final fix", style: "bg-blue-100 text-blue-700", agentic: true),
      Entry.new(kind: "auto_merge", handler: "AutoMerge", label: "Auto-merge", style: "bg-green-100 text-green-700", agentic: false),
      Entry.new(kind: "merge_train_assemble", handler: "MergeTrainAssemble", label: "Assemble train", style: "bg-green-100 text-green-800", agentic: false),
      Entry.new(kind: "merge_train_build", handler: "MergeTrainBuild", label: "Build integration branch", style: "bg-green-100 text-green-800", agentic: true),
      Entry.new(kind: "merge_train_land", handler: "MergeTrainLand", label: "Land Epic", style: "bg-green-100 text-green-800", agentic: false),
      Entry.new(kind: "merge_train_rebase", handler: "MergeTrainRebase", label: "Rebase integration branch", style: "bg-teal-100 text-teal-700", agentic: false),
      Entry.new(kind: "merge_train_land_after_rebase", handler: "MergeTrainLandAfterRebase", label: "Land Epic after rebase", style: "bg-green-100 text-green-800", agentic: false),
      Entry.new(kind: "manual", handler: "Manual", label: "Manual", style: "bg-gray-100 text-gray-700", agentic: true),
      Entry.new(kind: "coverage_analyze", handler: "CoverageAnalyze", label: "Analyze coverage", style: "bg-yellow-100 text-yellow-700", agentic: false)
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
