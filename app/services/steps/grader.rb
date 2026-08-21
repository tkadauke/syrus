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
      runner_result = nil

      sink, flush = buffered_log_sink
      span_plan = GraderCommandSpans::Plan.for(command)
      span_recorder = GraderCommandSpans::Recorder.new(run: run, step: step, workflow: workflow, plan: span_plan)
      runner_command = span_recorder.wrap(span_plan.shell_command)

      git_status_before = capture_git_status(name: name)

      File.open(absolute_log_path, "wb") do |file|
        runner_result = run_with_span_recording(
          runner_command: runner_command,
          display_command: command,
          timeout_minutes: timeout_minutes,
          span_recorder: span_recorder,
          file: file,
          sink: sink
        )

        timed_out = runner_result.timed_out
        exit_code = timed_out ? TIMEOUT_EXIT_CODE : runner_result.exit_status
        trailing_chunk = span_recorder.flush_visible
        if trailing_chunk.present?
          file.write(trailing_chunk)
          file.flush
          sink.call(trailing_chunk, kind: "grade_log")
        end
        span_recorder.finalize!(
          exit_code: exit_code,
          timed_out: timed_out,
          stopped: runner_result.stopped,
          operator_killed: runner_result.operator_killed
        )

        if timed_out
          timeout_message = "\n[timed out after #{timeout_minutes} minutes]\n"
          file.write(timeout_message)
          log(timeout_message, kind: "grade_log")
          log("[grader:#{name}] timed out after #{timeout_minutes} minutes")
        end
      end

      flush.call
      capture_sccache_stats!(step_kind: "grader", label: name)

      record_grader_side_effect_warning!(
        name: name,
        command: command,
        before_status: git_status_before,
        after_status: capture_git_status(name: name)
      )

      duration_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      passed = runner_result&.success?

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

      run_grader_augmentors!(name: name, command: command) unless passed

      ingest_test_output!(name, definition["junit_output"]) if definition["junit_output"].present?

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

    # Non-fatal side-effect detector — grader pass/fail is completely
    # untouched by this. A grader command is meant to validate, not mutate;
    # when one leaves uncommitted changes it usually means either the
    # generated output should be gitignored, or the command belongs in
    # .syrus.yml's formatters:/generated: section instead of grade:. See
    # config/syrus_docs/workflow_warnings.md. Runs a plain synchronous
    # subprocess rather than going through GitRunner/ProcessRunner — this is
    # a fast, internal, non-interactive check, not a command whose spans,
    # timeouts, or kill-switch matter the way a real grader command's does.
    def capture_git_status(name:)
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain", chdir: workspace.path.to_s)
      return nil unless status.success?

      stdout
    rescue StandardError => e
      log("[grader:#{name}] warning: git status check failed (skipping side-effect detection): #{e.class}: #{e.message}")
      nil
    end

    def record_grader_side_effect_warning!(name:, command:, before_status:, after_status:)
      return if before_status.nil? || after_status.nil?
      return if before_status == after_status

      changed_files = git_status_diff_paths(before_status, after_status)
      return if changed_files.empty?

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        severity: "medium",
        title: "Grader #{name.inspect} produced uncommitted changes",
        evidence: { "grader_name" => name, "command" => command, "changed_files" => changed_files },
        suggested_prompt: grader_side_effect_prompt(name: name, command: command, changed_files: changed_files)
      )
    rescue StandardError => e
      log("[grader:#{name}] warning: failed to record grader side-effect warning: #{e.class}: #{e.message}")
    end

    # WorkflowWorkspace#setup registers ".syrus/" in .git/info/exclude, so in
    # a normally-set-up workspace `git status --porcelain` already omits our
    # own .syrus/grade-output/... log files. Filtering them here too is
    # belt-and-suspenders — Syrus's own bookkeeping writes are never a
    # "grader mutated the codebase" finding, exclude entry or not.
    def git_status_diff_paths(before_status, after_status)
      before_lines = before_status.to_s.each_line.map(&:chomp).to_set
      after_lines = after_status.to_s.each_line.map(&:chomp).to_set
      changed_lines = (before_lines - after_lines) | (after_lines - before_lines)
      changed_lines.filter_map { |line| git_status_line_path(line) }.reject { |path| path.start_with?(".syrus/") }.uniq
    end

    def git_status_line_path(line)
      return if line.blank?

      path = line[3..].to_s.strip
      path.include?(" -> ") ? path.split(" -> ").last.strip : path
    end

    def grader_side_effect_prompt(name:, command:, changed_files:)
      <<~PROMPT.strip
        Grader `#{name}` (`#{command}`) produced uncommitted changes to the workspace when it ran on this Job (files: `#{changed_files.join(', ')}`). Run this grader locally and reproduce the output. Determine whether the generated/modified files should be gitignored — if so, add them to `.gitignore` and stop. If not, root-cause why the grader produces this output. If the output is genuinely important and should be committed, consider moving this grader's command from `grade:` to `.syrus.yml`'s `formatters:` or `generated:` section instead, so it runs as an explicit deterministic pass rather than a validation step. Otherwise, use your judgment to fix the grader (or its command/config) so it does not mutate the codebase when run as a grader in this project.
      PROMPT
    end

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/iteration-#{run.iteration}/#{name}.log")
    end

    def append_grade_diagnostic(path, text)
      File.open(path, "ab") { |file| file.write(text) }
      log(text, kind: "grade_log")
    end

    def run_grader_augmentors!(name:, command:)
      Syrus::PluginRegistry.providers_for(:grader_augmentor).each do |provider|
        lines = PerformanceLogging.plugin_call(extension_point: :grader_augmentor, provider: provider, operation: :augment_grader_failure) do
          provider.augment_grader_failure(name: name, command: command, workspace_path: workspace.path)
        end
        Array(lines).each { |line| log(line, kind: "grade_log") }
      end
    end

    def grader_output_excerpt(path)
      return "" unless path.exist?
      output = path.binread
      output = output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def ingest_test_output!(grader_name, output_path_str)
      absolute_path = workspace.path.join(output_path_str)
      unless absolute_path.exist?
        log("[grader:#{grader_name}] junit_output #{output_path_str.inspect} not found — skipping ingestion")
        return
      end

      parser_name, parsed = try_plugin_parsers(absolute_path)
      parser_name, parsed = [ "JunitXmlParser", JunitXmlParser.parse(absolute_path.read) ] if parsed.nil?
      TestRunIngester.new(run: run, grader_name: grader_name, parsed_run: parsed).ingest!
      log("[grader:#{grader_name}] ingested #{parsed.total_count} test case(s) from #{output_path_str}")
    rescue JunitXmlParser::ParseError => e
      log("[grader:#{grader_name}] warning: JunitXmlParser: JUnit XML parse error: #{e.message}")
    rescue StandardError => e
      log("[grader:#{grader_name}] warning: test output ingestion failed via #{parser_name || "JunitXmlParser"}: #{e.class}: #{e.message}")
    end

    def try_plugin_parsers(absolute_path)
      Syrus::PluginRegistry.providers_for(:test_result_parser).each do |provider|
        can_parse = PerformanceLogging.plugin_call(extension_point: :test_result_parser, provider: provider, operation: :can_parse) do
          provider.can_parse?(output_path: absolute_path)
        end
        next unless can_parse

        parsed = PerformanceLogging.plugin_call(extension_point: :test_result_parser, provider: provider, operation: :call) do
          provider.call(output_path: absolute_path)
        end
        return [ provider.to_s, parsed ]
      end
      [ nil, nil ]
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD)
    end
  end
end
