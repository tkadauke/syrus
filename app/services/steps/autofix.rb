module Steps
  # Deterministic-formatter step that runs after the agentic step
  # (implement/respond) and before the grader retry loop's check phase.
  # Language plugins register :autofix_command providers (Ruby's
  # `rubocop -a`, JavaScript's `eslint --fix`/`prettier --write`, Go's
  # `gofmt -w`, Python's `ruff format`/`black`); this step runs whichever
  # commands apply to the repo and commits any resulting changes, so a
  # style-only grader failure a formatter could have resolved for free
  # doesn't cost the agent a full turn to notice and fix by hand.
  #
  # Autofix command failure is always soft — log a warning and move on to
  # the next command / to grading, the same posture RepoPrepPlan's guessed
  # (auto-detected) commands take in Steps::Prepare. An autofix tool
  # erroring (missing dependency, bad config, remaining unfixable
  # offenses) must not block the workflow the way an explicit `.syrus.yml`
  # grader failure does — whatever it managed to fix still gets committed.
  class Autofix < Base
    PER_COMMAND_TIMEOUT = 5.minutes.to_i
    OUTPUT_TAIL_BYTES = 8.kilobytes

    def call
      workspace.setup
      commands = autofix_commands

      if commands.empty?
        log("[autofix] no autofix commands registered for this repo — skipping")
        return
      end

      commands.each_with_index do |cmd, i|
        log("[autofix] (#{i + 1}/#{commands.size}) $ #{cmd}")
        run_shell(cmd)
      end

      commit_agent_changes("Autofix: apply deterministic formatting")
    end

    private

    def autofix_commands
      Syrus::PluginRegistry.providers_for(:autofix_command).filter_map do |provider|
        PerformanceLogging.plugin_call(extension_point: :autofix_command, provider: provider, operation: :autofix_command) do
          provider.autofix_command(workspace_path: workspace.path)
        end
      end
    end

    def run_shell(cmd)
      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        kind: "autofix",
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk)
          log(chunk, kind: "system")
        }
      ).run

      return if result.success? && !result.timed_out

      record_autofix_failure!(cmd, result, tail)
    end

    def append_output_tail(tail, chunk)
      tail << chunk.to_s
      overflow = tail.bytesize - OUTPUT_TAIL_BYTES
      tail.replace(tail.safe_byteslice(-OUTPUT_TAIL_BYTES, OUTPUT_TAIL_BYTES)) if overflow.positive?
    end

    # Non-fatal by construction: appends to a details/artifact array
    # (rather than overwriting a single key like Prepare's soft failure)
    # since multiple autofix commands can each fail independently in one
    # Step run, and every one of them should still be visible.
    def record_autofix_failure!(cmd, result, tail)
      failure = {
        "command" => cmd,
        "workdir" => workspace.path.to_s,
        "exit_status" => result.exit_status,
        "timed_out" => result.timed_out?,
        "duration_s" => result.duration_s&.round(2),
        "output_tail" => compact_output_tail(tail),
        "soft" => true
      }
      failures = Array(step.details&.dig("autofix_failures")) + [ failure ]
      step.update!(details: (step.details || {}).merge("autofix_failures" => failures))
      workflow.set_artifact!("autofix_failures", failures)
      log("[autofix] WARNING (non-fatal): command failed (exit #{failure['exit_status'] || 'unknown'}): #{cmd}")
    end

    def compact_output_tail(tail)
      tail.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").strip
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD, extra: workspace_dependency_env)
    end
  end
end
