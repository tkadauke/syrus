module Evals
  # Invokes a real agent against a scenario's fixture workspace. Reuses the
  # same one-shot invocation path AgentProviders.run_one_shot delegates to
  # (AgentProviders::Claude/Codex.invoke_one_shot) rather than that helper
  # itself, because run_one_shot always hands the provider a fresh empty
  # Dir.mktmpdir -- evals need a pre-seeded fixture workspace instead. The
  # `runner:` argument is the same RunJob.agent_runner-shaped test seam
  # ClaudeInvocation/CodexInvocation accept everywhere else in the app: nil
  # shells out to the real CLI, a fake proc lets specs avoid that entirely.
  module AgentRun
    Result = Struct.new(
      :success, :timed_out, :is_error, :outcome, :final_text,
      :transcript_text, :cost_usd, :turns, :diff, :history_intact,
      keyword_init: true
    )

    def self.call(scenario:, workspace_path:, user:, provider:, runner: RunJob.agent_runner, log_sink: ->(*, **) {})
      base_ref = scenario.history_ancestor_ref.presence || FixtureWorkspace.head_sha(workspace_path)

      klass = AgentProviders.for(provider)
      result = klass.invoke_one_shot(
        workspace_path: workspace_path,
        user: user,
        runner: runner,
        scope: "eval-#{scenario.slug}",
        prompt: scenario.prompt,
        log_sink: log_sink,
        timeout: scenario.timeout_seconds,
        max_turns: scenario.max_turns
      )

      Result.new(
        success: result.success?,
        timed_out: result.timed_out,
        is_error: result.is_error,
        outcome: result.outcome,
        final_text: result.final_text,
        transcript_text: TranscriptRenderer.render(result.transcript_jsonl),
        cost_usd: result.cost_usd,
        turns: result.turns,
        diff: FixtureWorkspace.diff(workspace_path, base_ref),
        history_intact: FixtureWorkspace.history_intact?(workspace_path, base_ref)
      )
    end
  end
end
