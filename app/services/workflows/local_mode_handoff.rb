module Workflows
  # Triggered by complete_implement_step after the Local Mode daemon has
  # committed and pushed the implementation. Skips the agent implement step
  # (code is already on the branch) and goes straight to graders, then
  # wraps up based on whether the Job already has a PR or not.
  class LocalModeHandoff < Base
    def self.trigger_kind = "local_mode_handoff"

    def self.steps_for(job)
      chain = if job.pr_number.present?
        # PR already exists (taken-over implemented Job) — update it
        [
          "prepare",
          "grader_fanout",
          "grader_collect",
          "summarize_amend",
          follow_up_push(max_iterations: AppSetting.grade_max_iterations)
        ]
      else
        # No PR yet (new coding Job) — open one after graders pass
        [
          "prepare",
          "grader_fanout",
          "grader_collect",
          "summarize",
          "test_plan",
          "pr_open"
        ]
      end
      prepare_skipped_for?(job) ? chain.reject { |node| node == "prepare" } : chain
    end

  end
end
