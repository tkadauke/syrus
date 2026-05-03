module Workflows
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
    "retry"      => :Retry,
    "manual"     => :Manual,
    "resume"     => :Resume
  }.freeze

  def self.for(trigger_kind:)
    const_name = REGISTRY.fetch(trigger_kind.to_s) do
      raise ArgumentError, "no workflow template for trigger_kind=#{trigger_kind.inspect}"
    end
    const_get(const_name)
  end
end
