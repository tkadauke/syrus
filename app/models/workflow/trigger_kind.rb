class Workflow
  module TriggerKind
    Entry = Data.define(:kind, :template, :label, :style) do
      def template_class
        "Workflows::#{template}".constantize
      end
    end

    ENTRIES = [
      Entry.new(kind: "initial", template: "Initial", label: "Initial implementation", style: "bg-purple-100 text-purple-700"),
      Entry.new(kind: "pr_comment", template: "PrFeedback", label: "PR feedback", style: "bg-cyan-100 text-cyan-700"),
      Entry.new(kind: "chat_feedback", template: "ChatFeedback", label: "Chat feedback", style: "bg-indigo-100 text-indigo-700"),
      Entry.new(kind: "ci_failure", template: "CiFailure", label: "CI failure", style: "bg-red-100 text-red-700"),
      Entry.new(kind: "rebase", template: "Rebase", label: "Rebase", style: "bg-teal-100 text-teal-700"),
      Entry.new(kind: "stack_rebase", template: "StackRebase", label: "Stack rebase", style: "bg-teal-100 text-teal-700"),
      Entry.new(kind: "auto_merge", template: "AutoMerge", label: "Auto-merge", style: "bg-green-100 text-green-700"),
      Entry.new(kind: "merge_train", template: "MergeTrain", label: "Epic merge-train", style: "bg-green-100 text-green-800"),
      Entry.new(kind: "retry", template: "Retry", label: "Retry", style: "bg-amber-100 text-amber-700"),
      Entry.new(kind: "replay", template: "Retry", label: "Retry", style: "bg-amber-100 text-amber-700"),
      Entry.new(kind: "manual", template: "Manual", label: "Manual", style: "bg-gray-100 text-gray-700"),
      Entry.new(kind: "resume", template: "Resume", label: "Resume", style: "bg-fuchsia-100 text-fuchsia-700"),
      Entry.new(kind: "local_dev", template: "LocalDev", label: "Local dev", style: "bg-blue-100 text-blue-700")
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
  end
end
