module Steps
  class ManualAgenticRun < Base
    def call
      workspace.setup
      persist_prompt_if_needed

      log("invoking agent for manual_agentic_run step (#{workflow.slug}, step ##{step.id})")
      base_sha = head_sha
      run_agent(prompt: run.prompt)

      commit_agent_changes(job_commit_subject("Manual update"))
      assert_branch_history_intact!

      diff = diff_against_default
      if diff.blank?
        workflow.set_artifact!("manual_agentic_run_no_changes", true)
        run.update!(head_sha: head_sha, base_sha: base_sha, step_agent_diff: "")
        return if workflow.artifact("manual_agentic_run_github_access") == true

        cancel_downstream!(reason: "manual agentic run produced no changes")
        return
      end

      step_diff = diff_against_sha(base_sha)
      current_head_sha = head_sha
      if workflow.artifact("manual_agentic_run_github_access") == true && workflow.artifact("manual_agentic_run_push") == false
        raise StepFailed, "break-glass run produced local committed output but publication was disabled"
      end
      run.update!(agent_diff: diff, head_sha: current_head_sha, base_sha: base_sha, step_agent_diff: step_diff)
      persist_diff_review_version!(base_sha: base_sha, head_sha: current_head_sha, diff: step_diff)
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

        #{github_access_guidance}
      PROMPT
    end

    def github_access_guidance
      return "Authenticated GitHub access is unavailable. Do not attempt remote mutations." unless workflow.artifact("manual_agentic_run_github_access") == true

      destructive = workflow.artifact("manual_agentic_run_github_destructive") == true
      <<~TEXT
        BREAK-GLASS GITHUB ACCESS: authenticated gh api and Git transport are available only for #{repository.slug} during this step. High-level gh commands (including gh pr and gh issue) are unavailable because their GraphQL requests cannot be safely repository-bound; use repository-scoped gh api calls instead. Commands are audited and Syrus will verify the declared remote outcomes through its own provider client; your summary is not evidence. Other repositories and organizations are blocked. #{destructive ? "The operator separately confirmed destructive GitHub operations, including direct Git pushes." : "Destructive GitHub operations and direct Git pushes are unavailable and require a separate confirmed action; use Syrus's normal publication step for ordinary committed output."} Pending-action, permission, repository-policy, and secret-redaction boundaries still apply. Never print credentials, authentication environment, or credential-bearing URLs.
      TEXT
    end
  end
end
