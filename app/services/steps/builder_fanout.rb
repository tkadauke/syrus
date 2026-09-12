module Steps
  class BuilderFanout < Base
    include PrepareTargetExecution

    ARTIFACT_KEY = "opportunistic_builder_targets".freeze
    OUTPUT_INLINE_BYTES = 8 * 1024

    def call
      workspace.setup

      targets = candidate_targets
      if targets.empty?
        log("[builder_fanout] no hot builder targets configured")
        workflow.set_artifact!(ARTIFACT_KEY, [])
        return
      end

      files = changed_files
      selected = select_affected_targets(targets, files)
      if selected.empty?
        log("[builder_fanout] no hot builder targets affected by main branch change")
        workflow.set_artifact!(ARTIFACT_KEY, [])
        return
      end

      entries = selected.map { |selection| build_or_reuse!(selection) }
      workflow.set_artifact!(ARTIFACT_KEY, entries)
      step.update!(details: step.details.to_h.merge(ARTIFACT_KEY => entries))
    end

    private

    def candidate_targets
      target_graph.targets.values.select do |target|
        target.kind == "builder" && target.executable? && builder_policy.build_on_main?(target)
      end
    end

    def select_affected_targets(targets, files)
      return targets.map { |target| baseline_selection_for(target) } if files.empty?

      targets.filter_map do |target|
        selection = target_graph.affected(target.label, changed_files: files)
        if selection.affected
          log("[builder_fanout] selected #{target.label} (#{selection.reason})")
          selection
        else
          log("[builder_fanout] skipped #{target.label} (#{selection.reason})")
          nil
        end
      end
    end

    def baseline_selection_for(target)
      selection = TargetGraph::Selection.new(
        target: target,
        affected: true,
        reason: "baseline main build"
      )
      log("[builder_fanout] selected #{target.label} (#{selection.reason})")
      selection
    end

    def build_or_reuse!(selection)
      target = selection.target
      reusable = target_health_reuse.for_target(target.label)
      if reusable.reusable?
        log("[builder_fanout] skipped #{target.label} (#{reusable.reason})")
        return selection_entry(selection, "skipped", "reused target health", reusable.record_refs)
      end

      log("[builder_fanout] target health miss for #{target.label}: #{reusable.reason}")
      run_builder!(selection, reusable.fingerprints)
    rescue StandardError => e
      log("[builder_fanout] #{target&.label || selection.target.label} failed-soft: #{e.class}: #{e.message}")
      selection_entry(selection, "inconclusive", "#{e.class}: #{e.message}", [])
    end

    def run_builder!(selection, fingerprints)
      target = selection.target
      command = target.command
      timeout_minutes = target.timeout_minutes || 30
      workdir = builder_workdir(target)
      prepare_target_results = run_prepare_target_dependencies!(
        prepare_targets_for(target),
        requested_by: "#{step.kind}:#{target.label}"
      )
      log("[builder_fanout:#{target.label}] $ #{command}")

      log_path = builder_log_path(target)
      absolute_log_path = workspace.path.join(log_path)
      FileUtils.mkdir_p(absolute_log_path.dirname)

      started_at = Time.current
      runner_result = nil
      File.open(absolute_log_path, "wb") do |file|
        runner_result = ProcessRunner.new(
          env: env,
          command: [ "bash", "-c", command ],
          chdir: workdir,
          timeout: timeout_minutes.minutes,
          kind: "builder",
          run: run,
          workflow: workflow,
          display_command: command,
          on_output_chunk: ->(chunk) do
            file.write(chunk)
            file.flush
            log(chunk, kind: "builder_log")
          end
        ).run
      end
      finished_at = Time.current
      publish_command_completed!(step_kind: "builder_fanout", label: target.label.to_s)

      exit_code = runner_result.timed_out ? Grader::TIMEOUT_EXIT_CODE : runner_result.exit_status
      status = builder_status(runner_result)
      record = TargetHealthRecorder.record!(
        repository: repository,
        target_label: target.label.to_s,
        project_id: target.project_id,
        commit_sha: current_head_sha,
        input_fingerprint: fingerprints.input_fingerprint,
        command_fingerprint: fingerprints.command_fingerprint,
        environment_fingerprint: fingerprints.environment_fingerprint,
        status: status,
        workflow: workflow,
        step: step,
        run: run,
        checked_at: finished_at,
        started_at: started_at,
        finished_at: finished_at,
        duration_s: (finished_at - started_at).round(1),
        exit_code: exit_code,
        log_path: log_path.to_s,
        log_bytes: absolute_log_path.size,
        artifacts: builder_artifacts(target, workdir: workdir),
        metadata: {
          "prepare_target_results" => prepare_target_results,
          "selection_reason" => selection.reason,
          "target_fingerprints" => fingerprints.to_h,
          "workdir" => workdir.to_s,
          "output" => output_excerpt(absolute_log_path)
        }
      )

      log("[builder_fanout] recorded #{status} target health for #{target.label} at #{current_head_sha.first(7)}")
      selection_entry(selection, status, selection.reason, target_health_refs(record))
    end

    def builder_status(result)
      return "timed_out" if result.timed_out
      return "cancelled" if result.stopped || result.operator_killed

      result.success? ? "passed" : "failed"
    end

    def builder_artifacts(target, workdir:)
      paths = Array(target.metadata["artifacts"]).map(&:to_s).reject(&:empty?)
      return {} if paths.empty?

      existing = paths.flat_map { |path| existing_artifact_paths(path, workdir: workdir) }.uniq.filter_map do |path|
        absolute = workspace.path.join(path)
        next unless absolute.file?

        {
          "path" => path,
          "bytes" => absolute.size,
          "mtime" => absolute.mtime.iso8601
        }.compact
      end

      {
        "declared_paths" => paths,
        "existing_paths" => existing
      }
    end

    def existing_artifact_paths(pattern, workdir:)
      matches = Dir.glob(pattern, File::FNM_DOTMATCH, base: workdir.to_s)
        .reject { |path| path == "." || path.start_with?(".git/") || path.start_with?(".syrus/") }
        .map { |path| repo_relative_path(workdir.join(path)) }
        .select { |path| workspace.path.join(path).file? }

      matches.presence || [ repo_relative_path(workdir.join(pattern)) ]
    end

    def repo_relative_path(path)
      Pathname.new(path).relative_path_from(workspace.path).to_s
    end

    def selection_entry(selection, status, reason, record_refs)
      target = selection.target
      {
        "target_label" => target.label.to_s,
        "project_id" => target.project_id,
        "status" => status,
        "reason" => reason,
        "affected_reason" => selection.reason,
        "target_health_record_refs" => record_refs
      }.compact
    end

    def target_health_refs(record)
      [
        {
          "target_health_record_id" => record.id,
          "target_label" => record.target_label,
          "project_id" => record.project_id,
          "commit_sha" => record.commit_sha,
          "status" => record.status,
          "checked_at" => record.checked_at&.iso8601
        }.compact
      ]
    end

    def changed_files
      previous_sha = workflow.artifact("previous_main_sha").to_s.presence
      return [] unless previous_sha

      GitRunner.new.run("diff", "--name-only", "#{previous_sha}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[builder_fanout] warning: could not determine changed files: #{e.message}")
      []
    end

    def current_head_sha
      @current_head_sha ||= GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    end

    def builder_log_path(target)
      safe_label = target.label.to_s.delete_prefix("//").tr("^A-Za-z0-9._-", "_")
      Pathname.new(".syrus/builder-output/#{safe_label}.log")
    end

    def builder_workdir(target)
      project_path = target_project_path(target)
      path = project_path.present? ? workspace.path.join(project_path) : workspace.path
      return path if path.directory?

      raise StepFailed, "builder target #{target.label} project path does not exist: #{project_path}"
    end

    def target_project_path(target)
      target_graph.project(target.project_id)&.path.to_s
    end

    def prepare_targets_for(target)
      target_graph.prepare_dependencies_for(target.label).map do |prepare_target|
        project_path = target_project_path(prepare_target)
        {
          "target_label" => prepare_target.label.to_s,
          "commands" => Array(prepare_target.metadata.fetch("commands") { [ prepare_target.command ] }).flatten.map(&:to_s)
        }.tap do |payload|
          payload["project_path"] = project_path if project_path.present?
        end
      end
    end

    def prepare_dependency_status(result)
      return "timed out after #{Steps::Prepare::PER_COMMAND_TIMEOUT}s" if result.timed_out?
      return "operator killed" if result.operator_killed?
      return "stopped" if result.stopped?

      "exit #{result.exit_status || "unknown"}"
    end

    def capture_git_status(name:)
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain", chdir: workspace.path.to_s)
      return nil unless status.success?

      stdout
    rescue StandardError => e
      log("[builder_fanout:#{name}] warning: git status check failed (skipping side-effect detection): #{e.class}: #{e.message}")
      nil
    end

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

    def output_excerpt(path)
      return "" unless path.exist?

      output = path.binread
      output = output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def target_health_reuse
      @target_health_reuse ||= TargetHealthReuse.new(
        repository: repository,
        graph: target_graph,
        workspace_path: workspace.path
      )
    end

    def target_graph
      @target_graph ||= TargetGraph::Compiler.compile(workspace.path)
    end

    def builder_policy
      @builder_policy ||= OpportunisticBuilderPolicy.new
    end

    def env
      ProcessRunner.forwarded_env(
        Prepare.prep_env_forward,
        extra: workspace_dependency_env.merge(Prepare.prep_extra_env(workflow: workflow, workspace_path: workspace.path))
      )
    end

    class OpportunisticBuilderPolicy
      EXPENSIVE_COSTS = %w[expensive high very_high].freeze

      def build_on_main?(target)
        metadata = target.metadata.to_h
        return false if false_value?(metadata["opportunistic_build"]) || false_value?(metadata["main_build"])
        return true if true_value?(metadata["opportunistic_build"]) || true_value?(metadata["main_build"])
        return true if true_value?(metadata["hot"]) || true_value?(metadata["critical"])
        return true if positive_integer?(metadata["downstream_dependents"]) || positive_integer?(metadata["recent_failures"])
        return true if true_value?(metadata["release_relevance"])

        EXPENSIVE_COSTS.include?(metadata["cost"].to_s)
      end

      private

      def true_value?(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end

      def false_value?(value)
        value == false || value.to_s.in?(%w[false 0 off no])
      end

      def positive_integer?(value)
        Integer(value).positive?
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
