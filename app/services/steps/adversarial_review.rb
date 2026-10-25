module Steps
  class AdversarialReview < Base
    include ReviewExecutionPolicy

    FAILURE_SKIP_THRESHOLD = 1
    TURN_BUDGET = 200

    # The only failure this step is allowed to silently paper over by
    # repetition: the reviewer agent ran and simply never called the
    # required MCP tool. See #skippable_review_failure? and
    # #prior_failed_missing_tool_call_runs.
    MISSING_TOOL_CALL_PROBLEM_CODE = "missing_required_tool_call".freeze

    def call
      return if materialize_review_panel!

      workspace.setup
      run.update!(prompt: reviewer_prompt) if run.prompt.blank?

      before_count = review_iterations.size
      log("invoking agent for #{review_step_kind} step (#{workflow.slug}, step ##{step.id}, iteration #{step.iteration})")

      run_agent(prompt: run.prompt,
                max_turns: TURN_BUDGET,
                required_mcp_tools: [ review_submit_tool ],
                disallowed_tools: REVIEW_COLLIDING_TOOLS)
      discard_reviewer_workspace_changes

      workflow.reload
      if review_iterations.size <= before_count
        capture_mcp_sidecar_stderr
        if repeated_missing_tool_call_failures?
          reason = "reviewer did not call #{review_submit_tool} after " \
                   "#{prior_failed_missing_tool_call_runs} prior failed attempt(s) of the same kind"
          skip_review!(reason)
          skip_or_fail_unavailable_review!(
            review_kind: review_step_kind,
            reason: reason,
            message: reason,
            config_required: review_config&.required == true
          )
        end

        fail_with!(:missing_required_tool_call, "agent didn't call #{review_submit_tool}",
                   evidence: { tool: review_submit_tool })
      end
    rescue StandardError => e
      raise unless skippable_review_failure?(e)

      log("[#{review_step_kind}] skipped after reviewer failure: #{e.class}: #{e.message}", kind: "system")
      reason = "#{e.class}: #{e.message}"
      skip_review!(reason)
      skip_or_fail_unavailable_review!(
        review_kind: review_step_kind,
        reason: reason,
        message: reason,
        config_required: review_config&.required == true
      )
    end

    private

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || prior_member_session_id
    end

    def reviewer_prompt
      Prompts::AdversarialReview.new(
        issue: review_issue,
        diff: latest_agentic_diff,
        prior_findings: review_iterations.reject { |entry| entry["aggregate"] },
        base_ref: review_base_ref,
        workflow_kind: workflow.trigger_kind,
        feedback_context: feedback_context_text,
        criteria: adversarial_review_criteria,
        affected_projects: adversarial_review_projects.to_a
      ).to_s
    end

    def review_step_kind = "adversarial_review"
    def review_submit_tool = "submit_adversarial_review"
    def review_event_kind = "adversarial"
    def review_config = adversarial_review_config
    def review_skip_label = "Adversarial review"

    def adversarial_review_criteria
      [ *adversarial_review_projects.criteria, *plugin_review_criteria ].uniq
    end

    def adversarial_review_config
      return @adversarial_review_config if defined?(@adversarial_review_config)

      @adversarial_review_config = begin
        SyrusYml.load_repo(workspace.path).adversarial_review
      rescue SyrusYml::ParseError, Errno::ENOENT
        nil
      end
    end

    def adversarial_review_projects
      @adversarial_review_projects ||= App::AdversarialReviewProjects.call(
        workspace_path: workspace.path,
        changed_files: latest_agentic_changed_files
      )
    end

    def plugin_review_criteria
      Syrus::PluginRegistry.providers_for(:review_criteria_provider)
        .flat_map { |provider| Array(provider.criteria(workspace.path)) }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:empty?)
    end

    def review_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.issue_title.to_s, job.issue_body.to_s)
    end

    # Coding/local-mode handoff workflows have no implement/respond step in
    # their chain at all — the diff was produced by a chat coding session
    # before this workflow started, and any repair happens through
    # `coding_handoff_fix`/`local_mode_handoff_fix` instead. Mirror
    # Steps::VisualReview#latest_agentic_diff: only fall back to a fresh
    # `git diff` when the chain has no step of that kind at all; when one
    # exists but hasn't produced a diff yet, keep raising so a broken loop
    # iteration surfaces instead of silently reviewing stale state.
    def latest_agentic_diff
      @latest_agentic_diff ||=
        begin
          agentic_kind = feedback_workflow? ? "respond" : "implement"
          scope = workflow.steps.where(kind: agentic_kind)

          if scope.exists?
            latest_agentic_review_run(agentic_kind)
              &.then { |agentic_run| agentic_run.step_agent_diff.presence || agentic_run.agent_diff.presence }
              .presence || raise(StepFailed, "no succeeded #{agentic_kind} diff available for #{review_step_kind}")
          else
            diff_against_default.presence || raise(StepFailed, "no changes to review against #{default_branch_ref}")
          end
        end
    end

    def latest_agentic_changed_files
      latest_agentic_diff.to_s.scan(/^diff --git a\/.+ b\/(.+)$/).flatten
    end

    def latest_agentic_review_run(agentic_kind)
      workflow.steps.where(kind: agentic_kind, state: "succeeded")
        .order(:position)
        .last
        &.latest_run
    end

    def review_base_ref
      agentic_kind = feedback_workflow? ? "respond" : "implement"
      latest_agentic_review_run(agentic_kind)&.base_sha.presence || workspace.base_ref
    end

    def feedback_workflow?
      Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind).present?
    end

    def feedback_context_text
      Workflow::FeedbackKind.for(workflow)&.review_text
    end

    def review_iterations
      Array(workflow.artifact("adversarial_review_iterations"))
    end

    def prior_member_session_id
      prior = workflow.steps.where(kind: review_step_kind, loop_id: step.loop_id)
        .where("iteration < ?", step.iteration).order(iteration: :desc, position: :desc)
      if step.details.to_h["panel_member"]
        prior = prior.detect do |candidate|
          details = candidate.details.to_h
          details["panel_member"] && details["provider"] == step.details["provider"] && details["panel_id"] == step.details["panel_id"]
        end
        return prior&.latest_run&.provider_session&.session_id
      end
      prior.first&.latest_run&.provider_session&.session_id
    end

    def materialize_review_panel!
      return false if step.details.to_h["panel_member"]
      return true if step.details.to_h["panel_fanout"]

      decision = step.details.to_h["panel_execution"]
      return false unless decision

      members = Array(decision["members"])
      undersized = members.size < decision["min_members"].to_i
      return false if members.one? && !undersized
      raise StepFailed, "review panel has unavailable members and policy is fail" if decision["disposition"] == "fail"

      panel_id = decision.fetch("panel_id")
      continuation = step.next_step
      Step.transaction do
        workflow.steps.where("position >= ?", step.position + 1).update_all([ "position = position + ?", members.size + 1 ])
        member_steps = members.each_with_index.map do |member, index|
          Step.create!(
            workflow: workflow, kind: review_step_kind, position: step.position + index + 1,
            iteration: step.iteration, loop_id: step.loop_id,
            details: {
              "panel_member" => true, "panel_id" => panel_id,
              "provider" => member["provider"], "model" => member["model"], "effort_level" => member["effort_level"]
            }.compact
          )
        end
        collect = Step.create!(
          workflow: workflow, kind: "review_panel_collect", position: step.position + members.size + 1,
          iteration: step.iteration, loop_id: step.loop_id,
          placement_policy: Step::Kind.fetch("review_panel_collect").placement_policy_for(repository),
          details: {
            "panel_review_kind" => review_step_kind, "panel_id" => panel_id,
            "consensus" => decision.fetch("consensus"), "min_members" => decision.fetch("min_members"),
            "dropped_members" => decision.fetch("dropped_members"),
            "required" => review_config&.required == true
          }
        )
        chain = [ step, *member_steps, collect ]
        chain.each_cons(2) { |left, right| left.update!(next_step_id: right.id) }
        collect.update!(next_step_id: continuation&.id)
        step.update!(details: step.details.to_h.merge("panel_fanout" => true, "panel_id" => panel_id))
      end
      true
    end

    # Repetition alone never earns a silent skip — only the specific
    # missing-tool-call condition does. A repeated AgentTimedOut or
    # AgentGaveUpWaiting (real, plausible reviewer failure modes from
    # run_agent) must keep failing the step for real, not get papered
    # over just because the same problem code showed up twice in a row.
    def skippable_review_failure?(exception)
      prompt_too_long?(exception) ||
        (problem_code_for(exception) == MISSING_TOOL_CALL_PROBLEM_CODE && repeated_missing_tool_call_failures?)
    end

    def prompt_too_long?(exception)
      "#{exception.class}: #{exception.message}".match?(/prompt is too long|context.*too long|maximum context|context length/i)
    end

    def problem_code_for(exception)
      return nil unless exception.respond_to?(:problem)

      exception.problem&.code
    end

    def repeated_missing_tool_call_failures?
      prior_failed_missing_tool_call_runs >= FAILURE_SKIP_THRESHOLD
    end

    # Prior failed Runs on this Step whose recorded failure classification
    # (captured synchronously by CaptureRunDiagnostic before the Run is
    # marked failed) is the specific missing-tool-call condition. A prior
    # Run that failed for an unrelated reason (timeout, workspace error,
    # provider outage) must not count toward this threshold just because
    # it also happened to leave the Step in a "failed" state.
    def prior_failed_missing_tool_call_runs
      step.runs.where.not(id: run.id).where(state: "failed")
        .joins(:run_diagnostic)
        .where(run_diagnostics: { problem_code: MISSING_TOOL_CALL_PROBLEM_CODE })
        .count
    end

    def skip_review!(reason)
      critique = "#{review_skip_label} skipped: #{reason}"
      iterations = review_iterations
      iterations << {
        "iteration" => step.iteration,
        "step_id" => step.id,
        "run_id" => run.id,
        "critique" => critique,
        "verdict" => "skipped",
        "skipped" => true,
        "skip_reason" => reason
      }
      workflow.set_artifact!(Step::Kind.fetch(review_step_kind).review_gate.fetch(:artifact_key), iterations)
      ReviewFindingEvents.record(
        workflow: workflow,
        step: step,
        run: run,
        review_kind: review_event_kind,
        iteration: step.iteration,
        verdict: "skipped",
        critique: critique,
        skipped: true,
        skip_reason: reason
      )
      step.details = step.details.to_h.merge(
        "#{review_step_kind}_skipped" => true,
        "#{review_step_kind}_skip_reason" => reason
      )
      step.save!
    end

    def discard_reviewer_workspace_changes
      return unless File.exist?(workspace.path.join(".git"))

      status = GitRunner.new.run("status", "--porcelain", chdir: workspace.path.to_s)
      return if status.strip.empty?

      log("[#{review_step_kind}] discarding uncommitted reviewer workspace changes", kind: "system")
      git = streaming_git
      git.run("restore", "--staged", "--worktree", ".", chdir: workspace.path.to_s)
      git.run("clean", "-fd", chdir: workspace.path.to_s)
    end
  end
end
