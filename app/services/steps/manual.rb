module Steps
  # Single step of Manual workflows.
  #
  # Manual:  whatever prompt the operator passed in, no PR
  #          opening, no template — pure freeform agent run.
  #
  # The agent runs against the workspace, makes
  # whatever changes it wants, this handler doesn't push or open
  # a PR. If the operator wants the work persisted, they manually
  # promote it via the UI ("push branch" / "open PR") in a
  # follow-up flow. (Those affordances aren't built yet — for now,
  # the work lives in the workspace until the workflow's terminal
  # transition cleans up. v3 will add explicit "promote workflow
  # output" steps.)
  class Manual < Base
    def call
      workspace.setup
      log("invoking agent for manual step (#{workflow.slug}, trigger=#{workflow.trigger_kind})")

      raise StepFailed, "manual step requires a prompt on the Run" if run.prompt.blank?
      base_sha = head_sha
      run_agent(prompt: run.prompt)

      # Capture diff for posterity even though we don't push it.
      diff = diff_against_default rescue nil
      return if diff.blank?

      current_head_sha = head_sha
      step_diff = diff_against_sha(base_sha)
      run.update!(agent_diff: diff, head_sha: current_head_sha, base_sha: base_sha, step_agent_diff: step_diff)
      persist_diff_review_version!(base_sha: base_sha, head_sha: current_head_sha, diff: step_diff)
    end
  end
end
