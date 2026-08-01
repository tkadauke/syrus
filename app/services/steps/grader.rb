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
      timed_out = false

      sink, flush = buffered_log_sink
      span_plan = GraderCommandSpans::Plan.for(command)
      span_recorder = GraderCommandSpans::Recorder.new(run: run, step: step, workflow: workflow, plan: span_plan)
      runner_command = span_recorder.wrap(span_plan.shell_command)

      File.open(absolute_log_path, "wb") do |file|
        result = run_with_span_recording(
          runner_command: runner_command,
          display_command: command,
          timeout_minutes: timeout_minutes,
          span_recorder: span_recorder,
          file: file,
          sink: sink
        )

        timed_out = result.timed_out
        exit_code = timed_out ? TIMEOUT_EXIT_CODE : result.exit_status
        trailing_chunk = span_recorder.flush_visible
        if trailing_chunk.present?
          file.write(trailing_chunk)
          file.flush
          sink.call(trailing_chunk, kind: "grade_log")
        end
        span_recorder.finalize!(
          exit_code: exit_code,
          timed_out: timed_out,
          stopped: result.stopped,
          operator_killed: result.operator_killed
        )

        if timed_out
          timeout_message = "\n[timed out after #{timeout_minutes} minutes]\n"
          file.write(timeout_message)
          log(timeout_message, kind: "grade_log")
          log("[grader:#{name}] timed out after #{timeout_minutes} minutes")
        end
      end

      flush.call

      duration_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      passed = exit_code.to_i.zero?

      append_grade_diagnostic(absolute_log_path, "\n[grader:#{name}] failed (exit #{exit_code})\n") unless passed

      # Snapshot the result onto Step#details after all failure
      # augmentation so fallback readers see the same actionable tail as
      # the workspace log file when the workspace has been pruned.
      output_excerpt = grader_output_excerpt(absolute_log_path)
      step.update!(details: definition.merge(
        "exit_code" => exit_code,
        "duration_s" => duration_s.round(1),
        "timed_out" => timed_out,
        "log_path" => log_path.to_s,
        "log_bytes" => absolute_log_path.size,
        "output" => output_excerpt
      ))

      ingest_junit_xml!(name, definition["junit_output"]) if definition["junit_output"].present?
      raise StepFailed, "grader #{name} failed (exit #{exit_code})" unless passed
    end

    private

    def run_with_span_recording(runner_command:, display_command:, timeout_minutes:, span_recorder:, file:, sink:)
      ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", runner_command ],
        chdir: workspace.path,
        timeout: timeout_minutes.minutes,
        kind: "grader",
        run: run,
        workflow: workflow,
        display_command: display_command,
        on_spawned_process: ->(process) { span_recorder.spawned_process = process },
        on_output_chunk: ->(chunk) do
          visible_chunk = span_recorder.consume(chunk)
          next if visible_chunk.empty?

          file.write(visible_chunk)
          file.flush
          sink.call(visible_chunk, kind: "grade_log")
        end
      ).run
    rescue StandardError
      span_recorder.finalize!(exit_code: nil, timed_out: false)
      raise
    end

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/iteration-#{run.iteration}/#{name}.log")
    end

    def append_grade_diagnostic(path, text)
      File.open(path, "ab") { |file| file.write(text) }
      log(text, kind: "grade_log")
    end

    def grader_output_excerpt(path)
      return "" unless path.exist?
      output = path.binread
      output = output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def ingest_junit_xml!(grader_name, junit_output_path)
      absolute_path = workspace.path.join(junit_output_path)
      unless absolute_path.exist?
        log("[grader:#{grader_name}] junit_output #{junit_output_path.inspect} not found — skipping ingestion")
        return
      end

      parsed = JunitXmlParser.parse(absolute_path.read)
      TestRunIngester.new(run: run, grader_name: grader_name, parsed_run: parsed).ingest!
      log("[grader:#{grader_name}] ingested #{parsed.total_count} test case(s) from #{junit_output_path}")
    rescue JunitXmlParser::ParseError => e
      log("[grader:#{grader_name}] warning: JUnit XML parse error: #{e.message}")
    rescue StandardError => e
      log("[grader:#{grader_name}] warning: JUnit XML ingestion failed: #{e.class}: #{e.message}")
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD)
    end
  end
end
