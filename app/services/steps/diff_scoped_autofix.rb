module Steps
  # Shared machinery for Format and Generate — deterministic commands that
  # run on every grader-retry-loop iteration between the agentic step and
  # the grader check, each scoped to this iteration's diff. Both read their
  # command list from `.syrus.yml`, run whatever applies, and commit the
  # result.
  #
  # A command failing is always soft — log a warning and move on to the
  # next command / to grading, the same posture RepoPrepPlan's guessed
  # (auto-detected) commands take in Steps::Prepare. A broken
  # formatter/generator must never block the workflow the way an explicit
  # `.syrus.yml` grader failure does — whatever it managed to fix still
  # gets committed.
  module DiffScopedAutofix
    PER_COMMAND_TIMEOUT = 5.minutes.to_i
    OUTPUT_TAIL_BYTES = 8.kilobytes

    private

    # `git diff --name-only <base>...HEAD` — three-dot, same base as
    # #diff_against_default — so a command only runs when this Job's
    # branch actually touches files it cares about.
    def changed_files
      @changed_files ||= GitRunner.new.run(
        "diff", "--name-only", "#{default_branch_ref}...HEAD", chdir: workspace.path.to_s
      ).split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[#{step.kind}] warning: could not determine changed files: #{e.message}")
      []
    end

    # A blank/absent glob list means "no restriction" (matches
    # Steps::GraderFanout's when_files_changed semantics), not "matches
    # nothing".
    def files_match?(globs, files)
      return true if globs.nil? || globs.empty?

      files.any? { |file| globs.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) } }
    end

    def load_syrus_yml
      return nil unless workspace.path.join(SyrusYml::CONFIG_FILE).exist?

      SyrusYml.load_repo(workspace.path)
    rescue SyrusYml::ParseError => e
      log("[#{step.kind}] warning: .syrus.yml parse error: #{e.message}")
      nil
    end

    def run_commands(commands)
      commands.each_with_index do |cmd, i|
        log("[#{step.kind}] (#{i + 1}/#{commands.size}) $ #{cmd}")
        run_shell(cmd)
      end
    end

    def run_shell(cmd)
      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        kind: step.kind,
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk, max_bytes: OUTPUT_TAIL_BYTES)
          log(chunk, kind: "system")
        }
      ).run

      return if result.success? && !result.timed_out

      record_command_failure!(cmd, result, tail)
    end

    # Non-fatal by construction: appends to a details/artifact array (rather
    # than overwriting a single key) since multiple commands can each fail
    # independently in one Step run, and every one of them should still be
    # visible.
    def record_command_failure!(cmd, result, tail)
      key = "#{step.kind}_failures"
      failure = {
        "command" => cmd,
        "workdir" => workspace.path.to_s,
        "exit_status" => result.exit_status,
        "timed_out" => result.timed_out?,
        "duration_s" => result.duration_s&.round(2),
        "output_tail" => compact_output_tail(tail),
        "soft" => true
      }
      failures = Array(step.details&.dig(key)) + [ failure ]
      step.update!(details: (step.details || {}).merge(key => failures))
      workflow.set_artifact!(key, failures)
      log("[#{step.kind}] WARNING (non-fatal): command failed (exit #{failure['exit_status'] || 'unknown'}): #{cmd}")
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD, extra: workspace_dependency_env)
    end
  end
end
