module Workflows
  # Operator-confirmed, Job-scoped agentic repair run.
  #
  # Unlike legacy Manual workflows, this path is meant to participate in the
  # normal Job audit trail and publication machinery when requested. The agent
  # receives precise operator instructions, commits any changes, optionally
  # runs graders, then can summarize and push to the existing PR branch.
  class ManualAgenticRun < Base
    def self.trigger_kind = "manual_agentic_run"

    def self.steps_for(job)
      chain = [
        "prepare",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :manual_agentic_run ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "summarize_amend",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      ]
      prepare_skipped_for?(job) ? chain.reject { |node| node == "prepare" } : chain
    end
  end
end
