module Steps
  class ManualAgenticRun < Base
    def call
      workspace.setup
      persist_prompt_if_needed

      log("invoking agent for manual_agentic_run step (#{workflow.slug}, step ##{step.id})")
      base_sha = head_sha
      run_agent(prompt: run.prompt)

      commit_agent_changes("Syrus manual agentic run (will be rewritten by summarize)")
      assert_branch_history_intact!

      diff = diff_against_default
      if diff.blank?
        workflow.set_artifact!("manual_agentic_run_no_changes", true)
        run.update!(head_sha: head_sha, base_sha: base_sha, step_agent_diff: "")
        cancel_downstream!(reason: "manual agentic run produced no changes")
        return
      end

      step_diff = diff_against_sha(base_sha)
      run.update!(agent_diff: diff, head_sha: head_sha, base_sha: base_sha, step_agent_diff: step_diff)
    end

    private

    def persist_prompt_if_needed
      return if run.prompt.present?

      run.update!(prompt: compose_prompt)
    end

    def compose_prompt
      <<~PROMPT
        You are running an operator-confirmed manual repair workflow for #{job.slug} in #{repository.slug}.

        Operator reason:
        #{workflow.artifact("manual_agentic_run_reason")}

        Selected base:
        #{workflow.artifact("manual_agentic_run_base")}

        Operator instructions:
        #{workflow.artifact("manual_agentic_run_instructions")}

        Follow the operator instructions exactly. Keep changes tightly scoped. If the instructions ask for diagnostics or no code changes are needed, do not edit files; explain the diagnostic result in your final response. If you do change files, commit-ready edits are required. Syrus will run configured graders after this step and will #{workflow.artifact("manual_agentic_run_push") ? "push successful changes to the existing PR branch" : "not push changes from this workflow"}.
      PROMPT
    end
  end
end
