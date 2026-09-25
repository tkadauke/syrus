module Steps
  class VisualReview < Base
    def call
      workspace.setup

      if configured_when_files_changed.any? && !configured_changed_files_match?
        skip_via_pre_filter!
        return
      end

      if !visual_review_projects.available?
        skip_unavailable_preview_project!
        return
      end

      workflow.set_artifact!("visual_review_preview_projects", visual_review_projects.to_a)
      return unless prepare_previews!

      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for visual_review step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt,
                required_mcp_tools: %w[submit_visual_review],
                disallowed_tools: REVIEW_COLLIDING_TOOLS)
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
        capture_mcp_sidecar_stderr

        # Deliberately does not mirror Steps::AdversarialReview's swallow-and-approve
        # behavior after repeated missing-tool-call failures. That behavior is itself
        # under separate reconsideration for being too broad (it rescues any
        # StandardError, not just the missing-tool-call shape, once one prior Run on
        # the step has failed for any reason). Even a correctly-narrowed version would
        # still fake an "approved" verdict for visual QA, which is a worse failure mode
        # here than for text review: a stuck/retried Job is visible and recoverable, a
        # silently-approved-but-never-actually-reviewed UI regression is not. Raising
        # unconditionally also isn't a loss of resilience — RunFailureClassifier already
        # classifies this exact "agent didn't call submit_visual_review" shape as
        # `missing_required_tool_call` (retryable), so WorkEngine::RepairExecutor's
        # normal 5m/20m/1h auto-retry backoff already covers a transient reviewer miss
        # without this step needing to swallow it.
        fail_with!(:missing_required_tool_call, "agent didn't call submit_visual_review",
                   evidence: { tool: "submit_visual_review" })
      end

      VisualDiffSubmission.enqueue_deferred_for_visual_review(workflow)
    end

    private

    def prepare_previews!
      workflow.set_artifact!("visual_review_preview_preparation_failure", nil)
      if step.details.to_h.key?("preview_preparation_failure")
        step.update!(details: step.details.to_h.except("preview_preparation_failure"))
      end

      preparations = visual_review_projects.to_a.map do |project|
        project_id = project["id"] || project[:id]
        log("[visual_review] preparing preview project #{project_id}")
        PreviewPreparation.new(
          workspace.path,
          project_id: project_id,
          run: run,
          workflow: workflow,
          log: method(:log)
        ).call.merge("run_id" => run.id)
      end
      workflow.set_artifact!("visual_review_preview_preparations", preparations)
      true
    rescue PreviewPreparation::Error => e
      failure = e.details.merge(
        "run_id" => run.id,
        "step_id" => step.id,
        "occurred_at" => Time.current.iso8601
      )
      workflow.set_artifact!("visual_review_preview_preparation_failure", failure)
      step.update!(details: step.details.to_h.merge("preview_preparation_failure" => failure))
      log("[visual_review] preview preparation unavailable: #{e.message}")
      record_skip!("Visual review infrastructure could not prepare the preview (#{failure['reason']}): #{e.message}")
      false
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id ||
        workflow.steps
          .where(kind: "visual_review", loop_id: step.loop_id)
          .where("iteration < ?", step.iteration)
          .order(iteration: :desc)
          .first&.latest_run&.provider_session&.session_id
    end

    def reviewer_prompt
      Prompts::VisualReview.new(
        issue: review_issue,
        diff: review_diff,
        prior_findings: review_iterations,
        workflow_kind: workflow.trigger_kind,
        feedback_context: feedback_context_text,
        test_plan_recommended: test_plan_artifact["visual_review_recommended"],
        test_plan_reason: test_plan_artifact["visual_review_reason"],
        seed_notes: visual_review_seed_notes,
        preview_projects: visual_review_projects.to_a
      ).to_s
    end

    def test_plan_artifact
      workflow.artifact("test_plan").to_h
    end

    def visual_review_config
      return @visual_review_config if defined?(@visual_review_config)

      @visual_review_config = begin
        SyrusYml.load_repo(workspace.path).visual_review
      rescue SyrusYml::ParseError, Errno::ENOENT
        nil
      end
    end

    def visual_review_projects
      @visual_review_projects ||= App::VisualReviewProjects.call(
        workspace_path: workspace.path,
        changed_files: changed_files
      )
    end

    def visual_review_seed_notes
      [ visual_review_config&.seed_notes, visual_review_projects.seed_notes ].compact_blank.uniq.join("\n\n")
    end

    def configured_changed_files_match?
      changed_files_match?(configured_when_files_changed)
    end

    def changed_files_match?(patterns)
      changed_files.any? do |file|
        patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) }
      end
    end

    def configured_when_files_changed
      @configured_when_files_changed ||= [
        *Array(visual_review_config&.when_files_changed),
        *App::VisualReviewProjects.configured_when_files_changed(workspace_path: workspace.path)
      ].compact_blank.uniq
    end

    def changed_files
      scoped_diff = review_diff
      return diff_file_paths(scoped_diff) if scoped_diff.present?

      GitRunner.new.run("diff", "--name-only", "#{default_branch_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[visual_review] warning: could not determine changed files: #{e.message}")
      []
    end

    def skip_via_pre_filter!
      log("[visual_review] skipped: no changed files match visual_review.when_files_changed")
      record_skip!("No changed files matched the configured visual_review.when_files_changed patterns.")
    end

    def skip_unavailable_preview_project!
      reason = visual_review_projects.unavailable_reason
      message = skip_message_for(reason)
      log("[visual_review] skipped: #{message}")
      workflow.set_artifact!("visual_review_preview_projects_unavailable_reason", reason)
      record_skip!(message)
    end

    def skip_message_for(reason)
      {
        "no_preview_configured" => "No preview is configured for this repository.",
        "no_affected_preview_project" => "No affected project has a preview configured.",
        "no_affected_visual_review_project" => "No affected preview project has visual_review enabled.",
        "visual_review_project_resolution_failed" => "Could not resolve affected preview projects for visual review."
      }.fetch(reason.to_s, "Affected preview projects are unavailable for visual review.")
    end

    def record_skip!(critique)
      iterations = review_iterations
      iterations << {
        "iteration" => step.iteration,
        "step_id" => step.id,
        "run_id" => run.id,
        "critique" => critique,
        "verdict" => "skipped"
      }
      workflow.set_artifact!("visual_review_iterations", iterations)
    end

    def review_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.issue_title.to_s, job.issue_body.to_s)
    end

    # Standalone manual visual review workflows (Workflows::ManualVisualReview)
    # have no implement/respond step to read a diff off of — they run the
    # reviewer alone against whatever is already on the branch. Only fall
    # back to a fresh `git diff` when this workflow's chain has no step of
    # that kind at all; when one exists but hasn't produced a diff (still
    # running, failed, or genuinely produced nothing) keep raising so a
    # broken loop iteration surfaces instead of silently reviewing stale state.
    def review_diff
      latest_agentic_diff.presence
    end

    def latest_agentic_diff
      scope = workflow.steps.where(kind: agentic_kind)

      if scope.exists?
        latest_agentic_review_run
          &.then { |agentic_run| agentic_run.step_agent_diff.presence || agentic_run.agent_diff.presence }
          .presence || raise(StepFailed, "no succeeded #{agentic_kind} diff available for visual_review")
      else
        diff_against_default.presence || raise(StepFailed, "no changes to review against #{default_branch_ref}")
      end
    end

    def latest_agentic_review_run
      workflow.steps.where(kind: agentic_kind, state: "succeeded")
        .order(:position)
        .last
        &.latest_run
    end

    def agentic_kind
      feedback_workflow? ? "respond" : "implement"
    end

    def diff_file_paths(diff)
      diff.to_s.each_line.filter_map do |line|
        next unless line.start_with?("diff --git ")

        line[/\Ab\/(.+)\z/, 1] || line.split.last&.sub(/\Ab\//, "")
      end.compact_blank.uniq
    end

    def feedback_workflow?
      Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind).present?
    end

    def feedback_context_text
      Workflow::FeedbackKind.for(workflow)&.review_text
    end

    def review_iterations
      Array(workflow.artifact("visual_review_iterations"))
    end

    def discard_reviewer_workspace_changes
      return unless File.exist?(workspace.path.join(".git"))

      status = GitRunner.new.run("status", "--porcelain", chdir: workspace.path.to_s)
      return if status.strip.empty?

      log("[visual_review] discarding uncommitted reviewer workspace changes", kind: "system")
      git = streaming_git
      git.run("restore", "--staged", "--worktree", ".", chdir: workspace.path.to_s)
      git.run("clean", "-fd", chdir: workspace.path.to_s)
    end
  end
end
