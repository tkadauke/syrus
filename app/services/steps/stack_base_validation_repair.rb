module Steps
  # Agentic rung of the stacked-base finalization barrier for post-rebase
  # validation failures. The branch already descends from the parent head that
  # failed validation; the agent gets the grader commands and failure output and
  # repairs the tree. If the parent has moved again since, the next pr_open
  # rebases onto the newest head (bounded) before validating. Never pushes.
  class StackBaseValidationRepair < StackBaseAgentRebase
    PROMPT_KIND = "validation".freeze

    def call
      abort_rebase_if_present
      workspace.setup

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      repair = workflow.artifact(StackBaseFreshness::REPAIR_ARTIFACT).to_h
      parent_ref = repair["parent_ref"].presence || RebaseTarget.branch_for(job: job, workflow: workflow)
      pre_sha = head_sha

      run.update!(prompt: compose_repair_prompt(repair, parent_ref, repair["live_sha"], repair["prepared_sha"])) if run.prompt.blank?
      log("invoking agent for #{step.kind} step (#{workflow.slug})")
      run_agent(prompt: run.prompt)

      raise StepFailed, "#{step.kind}: working tree is not clean after repair" if git.run("status", "--porcelain", chdir: workspace.path.to_s).strip.present?
      raise StepFailed, "#{step.kind}: rebase left in progress" if rebase_in_progress?(git)

      post_sha = head_sha
      run.update!(head_sha: post_sha)
      log("#{step.kind}: #{pre_sha == post_sha ? 'no commit produced' : "#{pre_sha[0, 7]} -> #{post_sha[0, 7]}"}; graders re-run at pr_open")
    end
  end
end
