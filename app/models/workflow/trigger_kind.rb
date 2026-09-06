class Workflow
  module TriggerKind
    Entry = Data.define(:kind, :template, :label, :style, :retry_label, :feedback_kind, :runtime_role, :owns_job_lifecycle) do
      # owns_job_lifecycle defaults to false so existing built-in and
      # plugin-contributed entries that omit it keep the ordinary generic
      # workflow->Job propagation behavior.
      def initialize(owns_job_lifecycle: false, **rest)
        super(owns_job_lifecycle: owns_job_lifecycle, **rest)
      end

      # A plugin that owns a workflow keeps its template in its own namespace,
      # so a template containing "::" is taken as already fully qualified.
      def template_class
        template.to_s.include?("::") ? template.to_s.constantize : "Workflows::#{template}".constantize
      end
    end

    RUNTIME_ROLES = %w[first_class child infrastructure legacy].freeze

    BUILT_IN_ENTRIES = [
      Entry.new(kind: "initial",       template: "Initial",     label: "Initial implementation", style: "bg-purple-100 text-purple-700",  retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "pr_comment",    template: "PrFeedback",  label: "PR feedback",             style: "bg-cyan-100 text-cyan-700",      retry_label: "Retry failed step",  feedback_kind: :pr_comment, runtime_role: "first_class"),
      Entry.new(kind: "chat_feedback", template: "ChatFeedback", label: "Chat feedback",           style: "bg-indigo-100 text-indigo-700",  retry_label: "Retry failed step",  feedback_kind: :chat_feedback, runtime_role: "first_class"),
      Entry.new(kind: "ci_failure",    template: "CiFailure",   label: "CI failure",              style: "bg-red-100 text-red-700",        retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "rebase",        template: "Rebase",      label: "Rebase",                  style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "stack_rebase",  template: "StackRebase", label: "Stack rebase",            style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "promotion",     template: "Promotion",   label: "Promotion",               style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry promotion step", feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "hotfix_sync",   template: "HotfixSync",  label: "Hotfix sync",             style: "bg-fuchsia-200 text-fuchsia-800", retry_label: "Retry hotfix sync step", feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "upstream_export", template: "UpstreamExport", label: "Upstream export",    style: "bg-fuchsia-300 text-fuchsia-900", retry_label: "Retry upstream export step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "auto_merge",         template: "AutoMerge",        label: "Auto-merge",              style: "bg-green-100 text-green-700",    retry_label: "Retry landing step", feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "landing_validation", template: "LandingValidation", label: "Landing validation",      style: "bg-emerald-100 text-emerald-700", retry_label: nil,                  feedback_kind: nil, runtime_role: "child", owns_job_lifecycle: true),
      Entry.new(kind: "external_pr_merge",  template: "ExternalPrMerge",  label: "External PR merge",       style: "bg-green-100 text-green-700",    retry_label: "Retry landing step", feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "merge_train",   template: "MergeTrain",  label: "Epic merge-train",        style: "bg-green-100 text-green-800",    retry_label: nil,                  feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "merge_train_validation", template: "MergeTrainValidation", label: "Epic train validation", style: "bg-emerald-100 text-emerald-800", retry_label: nil, feedback_kind: nil, runtime_role: "child", owns_job_lifecycle: true),
      Entry.new(kind: "retry",         template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "manual_visual_review", template: "ManualVisualReview", label: "Manual visual review", style: "bg-pink-100 text-pink-700", retry_label: "Retry failed step", feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "visual_diff",   template: "VisualDiff",  label: "Before/after visual comparison", style: "bg-pink-50 text-pink-700", retry_label: "Retry failed step", feedback_kind: nil, runtime_role: "child"),
      Entry.new(kind: "replay",        template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "legacy"),
      Entry.new(kind: "manual",             template: "Manual",           label: "Manual",             style: "bg-gray-100 text-gray-700",       retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "resume",             template: "Manual",           label: "Resume",             style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "coding_handoff",     template: "CodingHandoff",    label: "Coding handoff",     style: "bg-violet-100 text-violet-700",   retry_label: "Retry grader step",  feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "local_mode_handoff", template: "LocalModeHandoff", label: "Local mode handoff", style: "bg-emerald-100 text-emerald-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "main_grader",          template: "MainGrader",        label: "Main branch grader",    style: "bg-gray-100 text-gray-500",       retry_label: nil,                  feedback_kind: nil, runtime_role: "infrastructure", owns_job_lifecycle: true),
      Entry.new(kind: "main_branch_repair",  template: "MainBranchRepair",  label: "Main branch repair",    style: "bg-red-100 text-red-800",         retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "manual_agentic_run",  template: "ManualAgenticRun",  label: "Manual agentic run",    style: "bg-fuchsia-100 text-fuchsia-700", retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "external_pr_ingest",  template: "ExternalPrIngest",  label: "External PR graders",   style: "bg-orange-100 text-orange-700",   retry_label: "Retry grader step",  feedback_kind: nil, runtime_role: "first_class", owns_job_lifecycle: true),
      Entry.new(kind: "external_pr_feedback", template: "ExternalPrFeedback", label: "External PR feedback", style: "bg-cyan-100 text-cyan-700",      retry_label: "Retry failed step",  feedback_kind: :pr_comment, runtime_role: "first_class"),
      Entry.new(kind: "skill",               template: "Skill",             label: "Skill run",             style: "bg-lime-100 text-lime-700",       retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class"),
      Entry.new(kind: "deploy",              template: "Deploy",            label: "Deploy",                 style: "bg-sky-100 text-sky-700",         retry_label: "Retry failed step",  feedback_kind: nil, runtime_role: "first_class")
    ].freeze

    # Plugins that own a workflow contribute their own trigger kinds through
    # :workflow_kinds; see Syrus::KindRegistry.
    REGISTRY = Syrus::KindRegistry.new(
      built_in: BUILT_IN_ENTRIES, entry_class: Entry, provider_method: :trigger_kinds
    )

    def self.entries = REGISTRY.entries
    def self.by_kind = REGISTRY.by_key

    # Workflow states that count as "still actively working" for guards that
    # must not let a Job move forward (e.g. re-approval, resubmission) while
    # a feedback workflow is queued or in flight. Shared so callers don't
    # hand-maintain their own copy of this list.
    ACTIVE_STATES = %w[queued running].freeze

    # Maintenance/QA trigger kinds that never change what's under review — a
    # rebase preserves the diff, a visual review/diff only inspects it. Their
    # being queued/running against an already-`implemented` Job must not hide
    # the Approve button, unlike an in-flight implementation workflow whose
    # diff isn't settled yet.
    NON_APPROVAL_BLOCKING_VALUES = %w[rebase stack_rebase manual_visual_review visual_diff].freeze

    module_function

    def values
      by_kind.keys.freeze
    end

    def epic_wide_values
      %w[merge_train stack_rebase].freeze
    end

    def epic_wide?(kind)
      epic_wide_values.include?(kind.to_s)
    end

    def fetch(kind)
      by_kind.fetch(kind.to_s) do
        raise ArgumentError, "unknown workflow trigger_kind=#{kind.inspect}"
      end
    end

    def template_for(kind)
      fetch(kind).template_class
    end

    def registry
      by_kind.transform_values(&:template).freeze
    end

    def runtime_role_for(kind)
      fetch(kind).runtime_role
    end

    def runtime_role_values(role)
      role = role.to_s
      raise ArgumentError, "unknown runtime_role=#{role.inspect}" unless RUNTIME_ROLES.include?(role)

      entries.select { |entry| entry.runtime_role == role }.map(&:kind).freeze
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

      by_kind.fetch(trigger_kind.to_s, nil)&.retry_label || "Retry failed step"
    end

    # Returns :chat_feedback, :pr_comment, or nil based on trigger kind.
    def feedback_kind_for(trigger_kind)
      by_kind.fetch(trigger_kind.to_s, nil)&.feedback_kind
    end

    # Trigger kinds that address feedback on an existing PR/chat (those with a
    # feedback_kind). Single source of truth so a new feedback kind can't be
    # missed by hand-maintained %w[pr_comment chat_feedback] lists.
    def feedback_values
      entries.select(&:feedback_kind).map(&:kind).freeze
    end

    # Single source of truth for the NON_APPROVAL_BLOCKING_VALUES check above,
    # so callers don't hand-roll `NON_APPROVAL_BLOCKING_VALUES.include?(...)`.
    def non_approval_blocking?(kind)
      NON_APPROVAL_BLOCKING_VALUES.include?(kind.to_s)
    end

    # Trigger kinds whose workflow definitions own their parent Job's
    # lifecycle through their own ad hoc machinery (landing services,
    # coding/local-mode handoff repair loops, external PR ingest, and
    # infrastructure workflows) rather than the generic
    # Workflows::JobLifecyclePropagation cascade. Single declarative place so
    # the exclusion list isn't scattered across hand-maintained predicate
    # checks.
    def owns_job_lifecycle?(trigger_kind)
      by_kind.fetch(trigger_kind.to_s, nil)&.owns_job_lifecycle || false
    end
  end
end
