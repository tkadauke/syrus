class Workflow
  module TriggerKind
    Entry = Data.define(:kind, :template, :label, :style, :retry_label, :feedback_kind, :runtime_role) do
      def template_class
        "Workflows::#{template}".constantize
      end
    end

    RUNTIME_ROLES = %w[first_class child infrastructure legacy].freeze

    ENTRIES = [
      Entry.new(kind: "initial",       template: "Initial",     label: "Initial implementation", style: "bg-purple-100 text-purple-700",  retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "pr_comment",    template: "PrFeedback",  label: "PR feedback",             style: "bg-cyan-100 text-cyan-700",      retry_label: "Retry failed step",  feedback_kind: :pr_comment, runtime_role: "first_class"),
      Entry.new(kind: "chat_feedback", template: "ChatFeedback", label: "Chat feedback",           style: "bg-indigo-100 text-indigo-700",  retry_label: "Retry failed step",  feedback_kind: :chat_feedback, runtime_role: "first_class"),
      Entry.new(kind: "ci_failure",    template: "CiFailure",   label: "CI failure",              style: "bg-red-100 text-red-700",        retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "rebase",        template: "Rebase",      label: "Rebase",                  style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "stack_rebase",  template: "StackRebase", label: "Stack rebase",            style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "promotion",     template: "Promotion",   label: "Promotion",               style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry promotion step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "auto_merge",         template: "AutoMerge",        label: "Auto-merge",              style: "bg-green-100 text-green-700",    retry_label: "Retry landing step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "landing_validation", template: "LandingValidation", label: "Landing validation",      style: "bg-emerald-100 text-emerald-700", retry_label: nil,                  feedback_kind: nil, runtime_role: "child"),
      Entry.new(kind: "external_pr_merge",  template: "ExternalPrMerge",  label: "External PR merge",       style: "bg-green-100 text-green-700",    retry_label: "Retry landing step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "merge_train",   template: "MergeTrain",  label: "Epic merge-train",        style: "bg-green-100 text-green-800",    retry_label: nil,                  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "merge_train_validation", template: "MergeTrainValidation", label: "Epic train validation", style: "bg-emerald-100 text-emerald-800", retry_label: nil, feedback_kind: nil, runtime_role: "child"),
      Entry.new(kind: "retry",         template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "manual_visual_review", template: "ManualVisualReview", label: "Manual visual review", style: "bg-pink-100 text-pink-700", retry_label: "Retry failed step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "replay",        template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "legacy"),
      Entry.new(kind: "manual",             template: "Manual",           label: "Manual",             style: "bg-gray-100 text-gray-700",       retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "resume",             template: "Manual",           label: "Resume",             style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "coding_handoff",     template: "CodingHandoff",    label: "Coding handoff",     style: "bg-violet-100 text-violet-700",   retry_label: "Retry grader step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "local_mode_handoff", template: "LocalModeHandoff", label: "Local mode handoff", style: "bg-emerald-100 text-emerald-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "main_grader",          template: "MainGrader",        label: "Main branch grader",    style: "bg-gray-100 text-gray-500",       retry_label: nil,                  feedback_kind: nil, runtime_role: "infrastructure"),
      Entry.new(kind: "main_branch_repair",  template: "MainBranchRepair",  label: "Main branch repair",    style: "bg-red-100 text-red-800",         retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "manual_agentic_run",  template: "ManualAgenticRun",  label: "Manual agentic run",    style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "agent_insight",       template: "AgentInsight",      label: "Agent insight",         style: "bg-amber-100 text-amber-700",     retry_label: nil,                  feedback_kind: nil, runtime_role: "infrastructure"),
      Entry.new(kind: "external_pr_ingest",  template: "ExternalPrIngest",  label: "External PR graders",   style: "bg-orange-100 text-orange-700",   retry_label: "Retry grader step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "external_pr_feedback", template: "ExternalPrFeedback", label: "External PR feedback", style: "bg-cyan-100 text-cyan-700",      retry_label: "Retry failed step",  feedback_kind: :pr_comment, runtime_role: "first_class"),
      Entry.new(kind: "skill",               template: "Skill",             label: "Skill run",             style: "bg-lime-100 text-lime-700",       retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "deploy",              template: "Deploy",            label: "Deploy",                 style: "bg-sky-100 text-sky-700",         retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class")
    ].freeze

    BY_KIND = ENTRIES.index_by(&:kind).freeze

    # Workflow states that count as "still actively working" for guards that
    # must not let a Job move forward (e.g. re-approval, resubmission) while
    # a feedback workflow is queued or in flight. Shared so callers don't
    # hand-maintain their own copy of this list.
    ACTIVE_STATES = %w[queued running].freeze

    module_function

    def values
      BY_KIND.keys.freeze
    end

    def epic_wide_values
      %w[merge_train stack_rebase].freeze
    end

    def epic_wide?(kind)
      epic_wide_values.include?(kind.to_s)
    end

    def fetch(kind)
      BY_KIND.fetch(kind.to_s) do
        raise ArgumentError, "unknown workflow trigger_kind=#{kind.inspect}"
      end
    end

    def template_for(kind)
      fetch(kind).template_class
    end

    def registry
      BY_KIND.transform_values(&:template).freeze
    end

    def runtime_role_for(kind)
      fetch(kind).runtime_role
    end

    def runtime_role_values(role)
      role = role.to_s
      raise ArgumentError, "unknown runtime_role=#{role.inspect}" unless RUNTIME_ROLES.include?(role)

      ENTRIES.select { |entry| entry.runtime_role == role }.map(&:kind).freeze
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

    # Returns the UI label for the "retry failed step" button on a workflow of
    # this trigger kind.
    def retry_label_for(trigger_kind, step_kind: nil)
      return "Rebuild merge train" if trigger_kind.to_s == "merge_train"

      BY_KIND.fetch(trigger_kind.to_s, nil)&.retry_label || "Retry failed step"
    end

    # Returns :chat_feedback, :pr_comment, or nil based on trigger kind.
    def feedback_kind_for(trigger_kind)
      BY_KIND.fetch(trigger_kind.to_s, nil)&.feedback_kind
    end

    # Trigger kinds that address feedback on an existing PR/chat (those with a
    # feedback_kind). Single source of truth so a new feedback kind can't be
    # missed by hand-maintained %w[pr_comment chat_feedback] lists.
    def feedback_values
      @feedback_values ||= ENTRIES.select(&:feedback_kind).map(&:kind).freeze
    end
  end
end
