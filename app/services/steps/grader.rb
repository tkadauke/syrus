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
    include PrepareTargetExecution

    TIMEOUT_EXIT_CODE = 124
    OUTPUT_INLINE_BYTES = 16 * 1024
    OUTPUT_CONTEXT_BEFORE_LINES = 8
    OUTPUT_CONTEXT_AFTER_LINES = 24
    OUTPUT_FAILURE_SNIPPET_LIMIT = 6
    OUTPUT_FAILURE_FOCUSED_BYTES = 28 * 1024
    FAILURE_OUTPUT_PATTERN = /
      (
        \bstuck:|
        \bfailed\s*\(exit\b|
        \bfail(?:ed|ure|ing)?\b|
        \berror\b|
        \bexception\b|
        \btraceback\b|
        \bunknown\b|
        \busage:\s*bin\/simulator\b|
        \bNoMethodError\b|
        \bNameError\b|
        \bArgumentError\b|
        \bRuntimeError\b|
        \bActiveRecord::\w+\b|
        \bMysql2::Error\b|
        \bSegmentation\ fault\b|
        \bNo\ space\ left\ on\ device\b
      )
    /ix
    FORMATTER_LIKE_GRADER_PATTERN = /
      \b(
        usort|black|ruff|rubocop|prettier|eslint|gofmt|rustfmt|swiftformat|ktlint|
        cargo\s+fmt|mix\s+format
      )\b
    /ix

    def call
      workspace.setup

      definition = step.details || {}
      name = definition.fetch("name") { raise StepFailed, "grader Step missing details[name]" }
      command = definition.fetch("command") { raise StepFailed, "grader Step missing details[command]" }
      timeout_minutes = (definition["timeout_minutes"] || 15).to_i
      prepare_target_results = run_prepare_target_dependencies!(definition["prepare_targets"], requested_by: "#{step.kind}:#{name}")

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
      span_recorder = GraderCommandSpans::Recorder.new(
        run: run,
        step: step,
        workflow: workflow,
        plan: span_plan,
        sequence_offset: run.command_spans.maximum(:sequence).to_i
      )
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
      publish_command_completed!(step_kind: "grader", label: name)

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
        "prepare_target_results" => prepare_target_results,
        "exit_code" => exit_code,
        "duration_s" => duration_s.round(1),
        "timed_out" => timed_out,
        "log_path" => log_path.to_s,
        "log_bytes" => absolute_log_path.size,
        "output" => output_excerpt
      ))

      record_formatter_like_grader_failure_warning!(
        name: name,
        command: command,
        exit_code: exit_code,
        timed_out: timed_out
      ) unless passed

      run_grader_augmentors!(name: name, command: command) unless passed

      announce_test_output!(name, definition["junit_output"]) if definition["junit_output"].present?

      unless passed
        unexplained_missing_exit = runner_result && exit_code.nil? &&
          !runner_result.stopped? && !runner_result.operator_killed? && !runner_result.silent_timed_out?
        if unexplained_missing_exit
          fail_with!(
            :worker_died,
            "grader #{name} process disappeared without an exit status",
            evidence: {
              "grader_name" => name,
              "aliveness_failed" => runner_result.aliveness_failed?,
              "stopped" => runner_result.stopped?,
              "operator_killed" => runner_result.operator_killed?,
              "silent_timed_out" => runner_result.silent_timed_out?
            }
          )
        end

        return if accept_failure_by_base_retry?(name: name, definition: definition)

        raise StepFailed, "grader #{name} failed (exit #{exit_code})"
      end

      check_new_test_flakiness!(name: name, definition: definition)
    end

    private

    def check_new_test_flakiness!(name:, definition:)
      return unless repository.new_test_flakiness_gate_enabled?
      return unless typed_test_grader?(definition)

      touched_files = touched_test_files_for(definition)
      return if touched_files.empty?

      log("[grader:#{name}] flaky_gate: checking #{touched_files.join(', ')} for day-one flakiness")
      result = TouchedTestRepeatGate.call(
        grader_step: step,
        touched_files: touched_files,
        repeats: new_test_flakiness_gate_repeats,
        workspace_path: workspace.path,
        env: env,
        log: ->(message) { log(message, kind: "system") }
      )
      return unless result.ran

      details = step.details.to_h.merge("new_test_flakiness_gate" => result.to_h.stringify_keys)
      if result.consistent
        step.update!(details: details)
        return
      end

      log_path = workspace.path.join(details["log_path"])
      append_grade_diagnostic(
        log_path,
        "\n[grader:#{name}] newly touched tests were flaky: #{result.fail_count}/#{result.repeats} repeat runs failed\n"
      )
      step.update!(details: details.merge("output" => grader_output_excerpt(log_path), "log_bytes" => log_path.size))
      fail_with!(
        :grader_failure,
        "newly touched tests failed intermittently: #{name} (#{result.fail_count}/#{result.repeats} failed)",
        evidence: { new_test_flakiness: true, result: result.to_h }
      )
    end

    def new_test_flakiness_gate_repeats
      repeats = repository.new_test_flakiness_gate_repeats
      repeats.nil? ? TouchedTestRepeatGate::DEFAULT_REPEATS : repeats
    end

    def typed_test_grader?(definition)
      definition["grader_framework"].to_s.in?(%w[rspec vitest])
    end

    def touched_test_files_for(definition)
      files = TouchedTestFiles.call(workspace_path: workspace.path, base_ref: base_revision_sha)
      patterns = Array(definition["when_files_changed"]).compact_blank
      return files if patterns.empty?

      files.select do |file|
        RepositoryContent::Glob.match?(patterns, file)
      end
    end

    def accept_failure_by_base_retry?(name:, definition:)
      return false unless definition["failures"] == MainBranchFailureClassifier::ALLOW_INHERITED
      return false if definition["base_retry"].blank?

      failed_cases = TestEvidenceLookup.failed_test_cases_for(run, name)
      return false if definition["junit_output"].present? && failed_cases.empty?

      base_sha = base_revision_sha
      return false if base_sha.blank?

      retry_result = BaseRevisionRetry.call(
        workflow: workflow,
        grader_step: step,
        base_sha: base_sha,
        failed_cases: failed_cases,
        log: ->(message) { log(message, kind: "system") }
      )
      record_base_retry_result!(retry_result, base_sha: base_sha)

      if retry_result.ran && retry_result.inherited
        accept_failure!(
          adjudicator: "base_revision_retry",
          reason: retry_result.reason,
          evidence: {
            "base_sha" => base_sha,
            "command" => retry_result.command,
            "failed_tests" => failed_cases,
            "base_failed_identities" => retry_result.base_failed_identities
          }
        )
        return true
      end

      accept_known_flaky_failure?(failed_cases)
    rescue StandardError => e
      log("[grader:#{name}] base-revision retry could not classify the failure: #{e.class}: #{e.message}")
      false
    end

    def record_base_retry_result!(result, base_sha:)
      step.update!(details: step.details.to_h.merge(
        "base_retry_result" => {
          "ran" => result.ran,
          "inherited" => result.inherited,
          "reason" => result.reason,
          "command" => result.command,
          "base_sha" => base_sha,
          "base_failed_identities" => result.base_failed_identities,
          "introduced_failed_identities" => result.introduced_failed_identities,
          "recorded_at" => Time.current.iso8601
        }.compact
      ))
    end

    def accept_known_flaky_failure?(failed_cases)
      verdict = Adjudicators::KnownFlakyFailure.adjudicate(
        problem: Problem[:grader_failure, evidence: { grader_names: [ step.details.to_h["name"] ] }],
        workflow: workflow,
        step: step
      )
      return false unless verdict.dismiss?

      accept_failure!(
        adjudicator: verdict.adjudicator,
        reason: verdict.reason,
        evidence: verdict.evidence.to_h.merge("failed_tests" => failed_cases)
      )
      true
    end

    def accept_failure!(adjudicator:, reason:, evidence:)
      accepted_failure = {
        "adjudicator" => adjudicator,
        "reason" => reason,
        "accepted_at" => Time.current.iso8601,
        "evidence" => evidence
      }
      step.update!(details: step.details.to_h.merge(
        "conclusion" => "warning",
        "accepted_failure" => accepted_failure
      ))
      log("[grader:#{step.details['name']}] accepted failing tests as #{reason}; grader completed with a warning")
    end

    def base_revision_sha
      return workflow.artifact("predicted_base_sha").presence if workflow.trigger_kind.in?(%w[landing_validation merge_train_validation])
      return job.mergeability_base_sha.presence if workflow.trigger_kind.in?(%w[auto_merge external_pr_merge])
      return workflow.artifact("merge_train_base_sha").presence if workflow.trigger_kind == "merge_train"

      base_ref = "origin/#{job.effective_base_branch.presence || repository.default_branch}"
      GitRunner.new.run("merge-base", "HEAD", base_ref, chdir: workspace.path.to_s, env: env).strip.presence
    rescue GitRunner::GitError => e
      log("[grader:#{step.details['name']}] could not resolve base revision for retry: #{e.message}")
      nil
    end

    def prepare_dependency_status(result)
      return "timed out after #{Steps::Prepare::PER_COMMAND_TIMEOUT}s" if result.timed_out?
      return "operator killed" if result.operator_killed?
      return "stopped" if result.stopped?

      "exit #{result.exit_status || "unknown"}"
    end

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

    def record_formatter_like_grader_failure_warning!(name:, command:, exit_code:, timed_out:)
      return unless formatter_like_grader?(name: name, command: command)

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "formatter_like_grader_failure",
        severity: timed_out ? "high" : "medium",
        title: "Formatter-like grader #{name.inspect} failed",
        evidence: {
          "grader_name" => name,
          "command" => command,
          "exit_code" => exit_code,
          "timed_out" => timed_out,
          "suggested_section" => "formatters"
        },
        suggested_prompt: formatter_like_grader_failure_prompt(name: name, command: command, timed_out: timed_out)
      )
    rescue StandardError => e
      log("[grader:#{name}] warning: failed to record formatter-like grader warning: #{e.class}: #{e.message}")
    end

    def formatter_like_grader?(name:, command:)
      "#{name} #{command}".match?(FORMATTER_LIKE_GRADER_PATTERN)
    end

    def formatter_like_grader_failure_prompt(name:, command:, timed_out:)
      timeout_note = timed_out ? " It timed out, so also check whether the command is being run too broadly and can be scoped to changed files." : ""
      <<~PROMPT.strip
        Grader `#{name}` (`#{command}`) looks like a deterministic formatter or style checker, but it failed while running as a required grader. Reproduce the command locally and decide whether this should remain a check-only grader or move to `.syrus.yml`'s `formatters:` section so Syrus can apply the deterministic change before graders run.#{timeout_note} If it must remain a grader, tighten the command/config so it is fast and reliable when run by Syrus.
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
      output = failure_focused_output_excerpt(output) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def failure_focused_output_excerpt(output)
      lines = output.lines
      matching_indexes = failure_context_indexes(lines)
      return output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if matching_indexes.empty?

      sections = []
      sections << "Output is #{output.bytesize} bytes; showing failure-focused excerpts. The full log may live in the grader checkout, so re-run the command if this is not enough.\n"
      sections << excerpt_section("Log head", output.safe_byteslice(0, 2.kilobytes))
      matching_indexes.first(OUTPUT_FAILURE_SNIPPET_LIMIT).each_with_index do |line_index, snippet_index|
        first = [ line_index - OUTPUT_CONTEXT_BEFORE_LINES, 0 ].max
        last = [ line_index + OUTPUT_CONTEXT_AFTER_LINES, lines.length - 1 ].min
        sections << excerpt_section("Failure context #{snippet_index + 1} around line #{line_index + 1}", lines[first..last].join)
      end
      sections << excerpt_section("Log tail", output.safe_byteslice(-4.kilobytes, 4.kilobytes))

      excerpt = sections.compact.join("\n")
      excerpt.bytesize > OUTPUT_FAILURE_FOCUSED_BYTES ? excerpt.safe_byteslice(0, OUTPUT_FAILURE_FOCUSED_BYTES) : excerpt
    end

    def failure_context_indexes(lines)
      indexes = []
      lines.each_with_index do |line, index|
        next unless line.match?(FAILURE_OUTPUT_PATTERN)
        next if simulator_success_line?(line)

        indexes << index
      end
      indexes
    end

    def simulator_success_line?(line)
      line.include?(": success after") || line.include?("(expected success")
    end

    def excerpt_section(title, text)
      return nil if text.blank?

      "== #{title} ==\n#{text}"
    end

    # Announces that a grader produced test output. Core does not parse or
    # store it: which parser applies and what a test case even is belong to
    # whichever plugin owns test results.
    #
    # Inline delivery, because the path is inside the workflow workspace and
    # that is torn down when the workflow reaches a terminal state.
    def announce_test_output!(grader_name, output_path_str)
      absolute_path = workspace.path.join(output_path_str)
      unless absolute_path.exist?
        log("[grader:#{grader_name}] junit_output #{output_path_str.inspect} not found - skipping ingestion")
        return
      end

      Syrus::Events.publish(
        "step.grader.completed",
        run_id: run.id,
        workflow_id: run.step&.workflow_id,
        repository_id: run.job&.repository_id,
        grader_name: grader_name,
        junit_output_path: absolute_path.to_s,
        format_hint: output_path_str.to_s.split(".").last,
        workspace_path: workspace.path.to_s
      )
    end

    def env
      extra_env = Prepare.prep_extra_env(scope: PrepareScope.for_workflow(workflow), workspace_path: workspace.path)
      ProcessRunner.forwarded_env(
        Prepare.prep_env_forward,
        extra: workspace_dependency_env.merge(extra_env)
      )
    end
  end
end
