class Workflow
  module TriggerKind
    Entry = Data.define(:kind, :template, :label, :style, :retry_label, :feedback_kind) do
      def template_class
        "Workflows::#{template}".constantize
      end
    end

    ENTRIES = [
      Entry.new(kind: "initial",       template: "Initial",     label: "Initial implementation", style: "bg-purple-100 text-purple-700",  retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "pr_comment",    template: "PrFeedback",  label: "PR feedback",             style: "bg-cyan-100 text-cyan-700",      retry_label: "Retry failed step",  feedback_kind: :pr_comment),
      Entry.new(kind: "chat_feedback", template: "ChatFeedback", label: "Chat feedback",           style: "bg-indigo-100 text-indigo-700",  retry_label: "Retry failed step",  feedback_kind: :chat_feedback),
      Entry.new(kind: "ci_failure",    template: "CiFailure",   label: "CI failure",              style: "bg-red-100 text-red-700",        retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "rebase",        template: "Rebase",      label: "Rebase",                  style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil),
      Entry.new(kind: "stack_rebase",  template: "StackRebase", label: "Stack rebase",            style: "bg-teal-100 text-teal-700",      retry_label: "Retry rebase step",  feedback_kind: nil),
      Entry.new(kind: "auto_merge",    template: "AutoMerge",   label: "Auto-merge",              style: "bg-green-100 text-green-700",    retry_label: "Retry landing step", feedback_kind: nil),
      Entry.new(kind: "merge_train",   template: "MergeTrain",  label: "Epic merge-train",        style: "bg-green-100 text-green-800",    retry_label: nil,                  feedback_kind: nil),
      Entry.new(kind: "retry",         template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "replay",        template: "Retry",       label: "Retry",                   style: "bg-amber-100 text-amber-700",    retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "manual",        template: "Manual",      label: "Manual",                  style: "bg-gray-100 text-gray-700",      retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "resume",         template: "Manual",         label: "Resume",                    style: "bg-fuchsia-100 text-fuchsia-700",  retry_label: "Retry failed step",  feedback_kind: nil),
      Entry.new(kind: "coding_handoff", template: "CodingHandoff", label: "Coding handoff",            style: "bg-violet-100 text-violet-700",    retry_label: "Retry grader step",  feedback_kind: nil),
      Entry.new(kind: "main_grader",    template: "MainGrader",    label: "Main branch grader",        style: "bg-gray-100 text-gray-500",        retry_label: nil,                  feedback_kind: nil)
    ].freeze

    BY_KIND = ENTRIES.index_by(&:kind).freeze

    module_function

    def values
      BY_KIND.keys.freeze
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
  end
end
