module Steps
  # Executes one grader command, captures its output, transitions the
  # Step accordingly. Per-grader-Step replacement for the inner loop
  # that lived in Steps::Grade — one Step per grader instead of one
  # Step per fanout. Grader Step failure does NOT cascade to a
  # workflow fail; StepDispatcher recognizes kind "grader" as a
  # silent-failure kind and advances to the next sibling regardless
  # of outcome. The iteration's grader_collect Step is what
  # aggregates pass/fail and triggers loop iteration if needed.
  #
  # Grader definition (name, command, description, required,
  # timeout_minutes) lives on Step#details — captured at materialize
  # time by Steps::GraderFanout, immutable for this Step. .syrus.yml
  # can evolve over the workflow's lifetime without re-interpreting
  # historical Steps.
  class Grader < Base
    TIMEOUT_EXIT_CODE = 124
    OUTPUT_INLINE_BYTES = 16 * 1024

    def call
      workspace.setup

      definition = step.details || {}
      name = definition.fetch("name") { raise StepFailed, "grader Step missing details[name]" }
      command = definition.fetch("command") { raise StepFailed, "grader Step missing details[command]" }
      timeout_minutes = (definition["timeout_minutes"] || 15).to_i

      log("[grader:#{name}] $ #{command}")

      log_path = grader_log_path(name)
      absolute_log_path = workspace.path.join(log_path)
      FileUtils.mkdir_p(absolute_log_path.dirname)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit_code = nil

      line_buffer = +""

      File.open(absolute_log_path, "wb") do |file|
        result = ProcessRunner.new(
          env: env,
          command: [ "bash", "-c", command ],
          chdir: workspace.path,
          timeout: timeout_minutes.minutes,
          kind: "grader",
          run: run,
          workflow: workflow,
          on_output_chunk: ->(chunk) do
            file.write(chunk)
            file.flush
            line_buffer << chunk
            while (nl = line_buffer.index("\n"))
              log(line_buffer.slice!(0..nl), kind: "grade_log")
            end
          end
        ).run

        exit_code = result.timed_out ? TIMEOUT_EXIT_CODE : result.exit_status

        if result.timed_out
          file.write("\n[timed out after #{timeout_minutes} minutes]\n")
          log("[grader:#{name}] timed out after #{timeout_minutes} minutes")
        end
      end

      log(line_buffer, kind: "grade_log") if line_buffer.present?

      duration_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      passed = exit_code.to_i.zero?

      # Snapshot the result onto Step#details so the UI + agent
      # prompt can render it later without re-reading the log file
      # (workspace gets pruned). Keep the per-grader log on disk
      # too, for full output when the operator drills in.
      output_excerpt = grader_output_excerpt(absolute_log_path)
      step.update!(details: definition.merge(
        "exit_code" => exit_code,
        "duration_s" => duration_s.round(1),
        "log_path" => log_path.to_s,
        "log_bytes" => absolute_log_path.size,
        "output" => output_excerpt
      ))

      raise StepFailed, "grader #{name} failed (exit #{exit_code})" unless passed
    end

    private

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/iteration-#{run.iteration}/#{name}.log")
    end

    def grader_output_excerpt(path)
      return "" unless path.exist?
      output = path.binread
      output = output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD)
    end
  end
end
