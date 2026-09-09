module Steps
  # Ensures a materialized grader Step's transitive `kind: prepare` target
  # dependencies (TargetGraph#prepare_dependencies_for, snapshotted onto
  # Step#details["prepare_targets"] by GraderFanout/PreflightGraderFanout)
  # run at most once per workflow workspace, not once per grader Step. See
  # "Prepare Semantics" in DOC-20: prepare targets are declared idempotent
  # environment setup, and root `prepare:` stays the unconditional
  # pre-implementation baseline this never touches -- this module only
  # covers explicit `kind: prepare` targets a grader depends on.
  #
  # A workspace-local marker (under `.syrus/prepare-targets/`, alongside
  # every other scratch directory a Step writes) records that a given
  # target's command already ran in *this* workspace, so a second grader
  # Step that also depends on it later in the same workflow reuses that
  # marker instead of re-running the command. A workspace that gets rebuilt
  # from scratch mid-workflow (a worker hop) has no marker and simply
  # re-runs the command there -- safe precisely because prepare targets are
  # supposed to be idempotent. An OS `flock` on a sibling lock file (held
  # only for the duration of one target's commands, released automatically
  # even if the holding process dies) keeps two grader Steps dispatched in
  # parallel from the same workflow (landing workflows can do this) from
  # racing to run the same target's commands concurrently.
  #
  # Included into Steps::Grader (and, through it, Steps::PreflightGrader).
  module PrepareTargetExecution
    MARKER_DIR = ".syrus/prepare-targets".freeze

    private

    # Runs (or reuses) every prepare target dependency in order, returning
    # one result Hash per target -- `"status"` is `"ran"` or `"reused"`,
    # `"reason"` is a human-readable explanation -- for the caller to
    # snapshot onto its own Step#details as an audit trail of what ran and
    # why.
    def run_prepare_target_dependencies!(prepare_targets, requested_by:)
      Array(prepare_targets).filter_map { |target| run_prepare_target!(target, requested_by: requested_by) }
    end

    def run_prepare_target!(target, requested_by:)
      label = target["target_label"].to_s
      commands = Array(target["commands"]).map(&:to_s).map(&:strip).reject(&:empty?)
      return nil if label.blank? || commands.empty?

      marker = prepare_marker_path(label)
      FileUtils.mkdir_p(marker.dirname)

      File.open(prepare_lock_path(label), File::CREAT | File::RDWR) do |lock_file|
        lock_file.flock(File::LOCK_EX)

        if (previous = read_prepare_marker(marker))
          reason = "already ran in this workflow workspace (requested by #{previous['requested_by']} at #{previous['ran_at']})"
          log("[#{step.kind}] prepare target #{label} #{reason} -- reusing for #{requested_by}")
          next { "target_label" => label, "status" => "reused", "commands" => commands, "reason" => reason }
        end

        log("[#{step.kind}] prepare target #{label} has not run in this workflow workspace yet -- running for #{requested_by}")
        execute_prepare_target_commands!(label: label, commands: commands)
        write_prepare_marker!(marker, requested_by: requested_by, ran_at: Time.current)
        { "target_label" => label, "status" => "ran", "commands" => commands, "reason" => "first use in this workflow workspace (requested by #{requested_by})" }
      end
    end

    def execute_prepare_target_commands!(label:, commands:)
      before_status = capture_git_status(name: "prepare:#{label}")

      commands.each_with_index do |command, index|
        log("[#{step.kind}] prepare target #{label} (#{index + 1}/#{commands.size}) $ #{command}")
        result = ProcessRunner.new(
          env: env,
          command: [ "bash", "-c", command ],
          chdir: workspace.path,
          timeout: Steps::Prepare::PER_COMMAND_TIMEOUT,
          kind: "prepare",
          run: run,
          workflow: workflow,
          display_command: command,
          on_output_chunk: ->(chunk) { log(chunk, kind: "prepare_log") }
        ).run
        publish_command_completed!(step_kind: "prepare", label: command)
        next if result.success? && !result.timed_out

        raise StepFailed, "prepare target #{label} failed (#{prepare_dependency_status(result)}): #{command}"
      end

      record_prepare_target_mutation_warning!(
        label: label,
        commands: commands,
        before_status: before_status,
        after_status: capture_git_status(name: "prepare:#{label}")
      )
    end

    # Same non-fatal posture as Steps::Grader's own
    # #record_grader_side_effect_warning! -- prepare targets are declared
    # idempotent environment setup that should not modify tracked source
    # files (DOC-20 "Prepare Semantics"); when one does, that's worth an
    # operator-visible finding, not a failed workflow.
    def record_prepare_target_mutation_warning!(label:, commands:, before_status:, after_status:)
      return if before_status.nil? || after_status.nil?
      return if before_status == after_status

      changed_files = git_status_diff_paths(before_status, after_status)
      return if changed_files.empty?

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "prepare_target_side_effect",
        severity: "medium",
        title: "Prepare target #{label.inspect} produced uncommitted changes",
        evidence: { "target_label" => label, "commands" => commands, "changed_files" => changed_files },
        suggested_prompt: prepare_target_side_effect_prompt(label: label, commands: commands, changed_files: changed_files)
      )
    rescue StandardError => e
      log("[#{step.kind}] warning: failed to record prepare target side-effect warning: #{e.class}: #{e.message}")
    end

    def prepare_target_side_effect_prompt(label:, commands:, changed_files:)
      <<~PROMPT.strip
        Prepare target `#{label}` (`#{commands.join(' && ')}`) produced uncommitted changes to the workspace when it ran as a prepare dependency on this Job (files: `#{changed_files.join(', ')}`). Prepare targets are supposed to be idempotent environment setup, not something that mutates tracked source files. Run this command locally and reproduce the output. Determine whether the changed files should be gitignored -- if so, add them to `.gitignore` and stop. If the output is genuinely important and should be committed, move this command out of `prepare:`/its `targets:` entry and into `.syrus.yml`'s `formatters:` or `generated:` section instead, so it runs as an explicit deterministic pass rather than idempotent setup. Otherwise, fix the command so it does not mutate the codebase when it runs as a prepare target.
      PROMPT
    end

    def prepare_marker_path(label)
      workspace.path.join(MARKER_DIR, "#{sanitize_prepare_label(label)}.json")
    end

    def prepare_lock_path(label)
      workspace.path.join(MARKER_DIR, "#{sanitize_prepare_label(label)}.lock")
    end

    def sanitize_prepare_label(label)
      label.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
    end

    def read_prepare_marker(marker)
      return nil unless marker.exist?

      JSON.parse(marker.read)
    rescue StandardError
      nil
    end

    def write_prepare_marker!(marker, requested_by:, ran_at:)
      marker.write(JSON.generate("requested_by" => requested_by, "ran_at" => ran_at.iso8601))
    end
  end
end
