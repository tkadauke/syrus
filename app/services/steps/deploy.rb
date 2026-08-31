module Steps
  # Runs the repository's `.syrus.yml` `deploy.run` command in the
  # workspace. Follows Prepare#run_shell's idiom (streamed output,
  # buffered JobLog chunks, per-command timeout, `kind:` tag on the
  # ProcessRunner call) but, unlike Prepare, there is no auto-detected
  # fallback for a deploy command: a missing/unparsable `.syrus.yml`, an
  # absent `deploy:` block, or a failing command are all hard failures —
  # any configured deploy failure is real, so it always raises StepFailed.
  class Deploy < Base
    PER_COMMAND_TIMEOUT = 15.minutes.to_i
    OUTPUT_TAIL_BYTES = 8.kilobytes

    def call
      workspace.setup
      command = deploy_config.run

      log("[deploy] $ #{command}")
      run_shell(command)
      log("[deploy] deploy command completed successfully")
    end

    private

    def deploy_config
      unless workspace.path.join(SyrusYml::CONFIG_FILE).exist?
        raise StepFailed, "no .syrus.yml found in workspace — deploy.run is not configured"
      end

      config = SyrusYml.load_repo(workspace.path).deploy
      raise StepFailed, "no deploy.run command configured in .syrus.yml" if config.blank?

      config
    rescue SyrusYml::ParseError => e
      raise StepFailed, ".syrus.yml could not be parsed: #{e.message}"
    end

    # `bash -c` so quoting / pipelines / && in the command work. cwd =
    # workspace path. Env scrubbed via Prepare::PREP_ENV_FORWARD +
    # unsetenv_others. Streams stdout+stderr (popen2e merges them) into
    # JobLog one buffered chunk at a time so the operator can watch the
    # deploy live. Hard timeout via a watcher thread that SIGTERMs the
    # process tree if it exceeds the budget.
    def run_shell(cmd)
      buffer = new_log_buffer
      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        kind: "deploy",
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk, max_bytes: OUTPUT_TAIL_BYTES)
          stream_buffered_chunk(buffer, chunk)
        }
      ).run
      flush_log_buffer(buffer)
      capture_sccache_stats!(step_kind: "deploy", label: cmd)

      return if result.success? && !result.timed_out

      failure = deploy_failure_payload(cmd, result, tail)
      record_deploy_failure!(failure)
      raise StepFailed, deploy_failure_message(failure)
    end

    def deploy_failure_payload(cmd, result, tail)
      {
        "command" => cmd,
        "workdir" => workspace.path.to_s,
        "exit_status" => result.exit_status,
        "timed_out" => result.timed_out?,
        "stopped" => result.stopped?,
        "operator_killed" => result.operator_killed?,
        "aliveness_failed" => result.aliveness_failed?,
        "duration_s" => result.duration_s&.round(2),
        "output_tail" => compact_output_tail(tail)
      }
    end

    def record_deploy_failure!(failure)
      step.update!(details: (step.details || {}).merge("deploy_failure" => failure))
      workflow.set_artifact!("deploy_failure", failure)
      log("[deploy] failure: #{deploy_failure_message(failure)}")
    end

    def deploy_failure_message(failure)
      status = if failure["timed_out"]
        "timed out after #{PER_COMMAND_TIMEOUT}s"
      elsif failure["operator_killed"]
        "operator killed"
      elsif failure["stopped"]
        "stopped"
      elsif failure["aliveness_failed"]
        "process disappeared"
      else
        "exit #{failure["exit_status"] || "unknown"}"
      end

      message = "deploy command failed (#{status}) in #{failure["workdir"]}: #{failure["command"]}"
      tail = failure["output_tail"].to_s
      return message if tail.blank?

      "#{message}\nOutput tail:\n#{tail}"
    end

    def new_log_buffer
      { content: +"", last_flush: Time.current }
    end

    def stream_buffered_chunk(buffer, chunk)
      buffer[:content] << chunk
      flush_log_buffer(buffer) if buffer[:content].bytesize >= LOG_FLUSH_MAX_BUF
    end

    def flush_log_buffer(buffer)
      return if buffer[:content].empty?

      log(buffer[:content].chomp, kind: "system")
      buffer[:content].clear
      buffer[:last_flush] = Time.current
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD, extra: workspace_dependency_env)
    end
  end
end
