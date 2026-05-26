module Steps
  # Registry of step-kind handlers. Same pattern as Workflows —
  # callers don't need to know the individual class names; they
  # ask `Steps.handler_for("implement").new(run).call`.
  REGISTRY = {
    "prepare"         => :Prepare,
    "implement"       => :Implement,
    "summarize"       => :Summarize,
    "pr_open"         => :PrOpen,
    "respond"         => :Respond,
    "summarize_amend" => :SummarizeAmend,
    "push"            => :Push,
    "analyze_and_fix" => :AnalyzeAndFix,
    "auto_rebase"     => :AutoRebase,
    "agent_rebase"    => :AgentRebase,
    "force_push"      => :ForcePush,
    "grade"           => :Grade,
    "grader"          => :Grader,
    "grader_fanout"   => :GraderFanout,
    "grader_collect"  => :GraderCollect,
    "auto_merge"      => :AutoMerge,
    "manual"          => :Manual
  }.freeze

  def self.handler_for(kind)
    const_name = REGISTRY.fetch(kind.to_s) do
      raise ArgumentError, "no handler for step kind=#{kind.inspect}"
    end
    const_get(const_name)
  end
end
