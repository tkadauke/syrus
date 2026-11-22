# The PR-opening tail of new-PR chains ends in a Try around pr_open whose
# branch resolves a stack-base rebase conflict with an agent
# (Workflows::Base.stack_aware_pr_open). Its id is a fresh UUID, so chain
# template pins match it instead of comparing it literally.
module StackAwarePrOpenHelpers
  def stack_aware_pr_open_node(max_iterations: AppSetting.grade_max_iterations)
    {
      "type" => "try",
      "id" => a_kind_of(String),
      "step" => "pr_open",
      "on_failure" => {
        "stack_base_rebase_conflict" => [
          { "type" => "step", "kind" => "stack_base_agent_rebase" },
          {
            "type" => "retry_until",
            "max_iterations" => max_iterations,
            "repair" => %w[ landing_fix ],
            "check" => %w[ grader_fanout grader_collect ],
            "repair_first" => false
          },
          { "type" => "step", "kind" => "pr_open" }
        ]
      }
    }
  end

  # steps_for lists hold strings and control nodes; a Try reads as its step.
  def step_kind_names(nodes)
    nodes.map { |node| node.is_a?(Workflows::Try) ? node.step_kind : node }
  end
end

RSpec.configure { |config| config.include StackAwarePrOpenHelpers }
