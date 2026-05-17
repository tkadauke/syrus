module Steps
  # Single step of Manual + Resume workflows.
  #
  # Manual:  whatever prompt the operator passed in, no PR
  #          opening, no template — pure freeform agent run.
  #
  # Resume:  identical pattern, with parent_session_id set on the
  #          Run (carried over from the dead Run that's being
  #          resumed) so ClaudeInvocation passes `--resume` and
  #          claude continues the prior conversation.
  #
  # Either way: the agent runs against the workspace, makes
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
      log("invoking agent for manual step (workflow ##{workflow.id}, trigger=#{workflow.trigger_kind})")

      raise StepFailed, "manual step requires a prompt on the Run" if run.prompt.blank?
      run_agent(prompt: run.prompt)

      # Capture diff for posterity even though we don't push it.
      diff = diff_against_default rescue nil
      run.update!(agent_diff: diff, head_sha: head_sha) if diff.present?
    end
  end
end
