module Workflows
  SKIP_PREPARE_LABEL = "syrus-skip-prepare".freeze

  def self.label_names(labels)
    Array(labels).map do |label|
      if label.respond_to?(:name)
        label.name
      elsif label.is_a?(Hash)
        label[:name] || label["name"] || label.to_s
      else
        label.to_s
      end
    end
  end

  # Registry of workflow templates keyed by trigger_kind. Callers
  # don't need to know the individual class names — they ask
  # `Workflows.for(trigger_kind: "pr_comment")` and get the right
  # template.
  #
  # The registry is built lazily from the loaded subclasses so
  # adding a new template is "create the file" — no edits here.
  REGISTRY = {
    "initial"    => :Initial,
    "pr_comment" => :PrFeedback,
    "ci_failure" => :CiFailure,
    "rebase"     => :Rebase,
    "auto_merge" => :AutoMerge,
    "retry"      => :Retry,
    "manual"     => :Manual,
    "resume"     => :Resume,
    "local_dev"  => :LocalDev
  }.freeze

  def self.for(trigger_kind:)
    const_name = REGISTRY.fetch(trigger_kind.to_s) do
      raise ArgumentError, "no workflow template for trigger_kind=#{trigger_kind.inspect}"
    end
    const_get(const_name)
  end
end
