module Steps
  # Materializes preflight grader Steps for a MainBranchRepair workflow.
  # Runs before the implement step; if the preflight graders all pass,
  # PreflightGraderCollect cancels the implement chain and the workflow
  # succeeds without the agent running.
  #
  # Resolves the grader plan via LandingGraderPlan's :ci phase (main_branch_repair
  # is a CI_TRIGGER_KINDS entry) rather than :landing, so preflight re-runs the
  # same ci-phase graders (e.g. rspec-ci) that mark ci_health broken — a grader
  # configured `phases: [landing]` only (e.g. a plain `rspec`) is not sufficient
  # evidence that the CI-only failures behind the repair have actually cleared.
  #
  # Unlike GraderFanout, this step:
  #   - Does NOT filter graders by when_files_changed (no PR diff exists yet)
  #   - Does NOT check the GraderConclusionCache for reuse (always runs fresh)
  #   - Does NOT call apply_loop_max_iterations! (not inside a retry loop)
  #   - Materializes Steps with kind "preflight_grader" to avoid collisions
  #     with the main grade loop's "grader" steps
  class PreflightGraderFanout < Base
    def call
      workspace.setup
      plan = effective_plan(RepoGradePlan.for(workspace.path))
      grader_fingerprint = GraderConclusionCache.fingerprint_for_plan(plan)

      workflow.set_artifact!("preflight_grade_plan_source", plan.source)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, grader_fingerprint)

      log("[preflight_grader_fanout] source: #{plan.source}")
      log("[preflight_grader_fanout] note: #{plan.note}") if plan.note

      if plan.graders.empty?
        log("[preflight_grader_fanout] no graders configured — collect step will pass through")
        return
      end

      if materialized_grader_steps.exists?
        log("[preflight_grader_fanout] grader steps already materialized; reusing existing step chain")
        return
      end

      materialize_grader_steps!(plan.graders)
      log("[preflight_grader_fanout] materialized #{plan.graders.size} grader step(s)")
    end

    private

    def effective_plan(plan)
      LandingGraderPlan.effective(plan, trigger_kind: workflow.trigger_kind, iteration: 1)
    end

    def materialize_grader_steps!(graders)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = graders.size

      Step.transaction do
        workflow.steps.where("position >= ?", insertion_position).update_all(
          [ "position = position + ?", offset ]
        )

        new_steps = graders.each_with_index.map do |grader, index|
          Step.create!(
            workflow: workflow,
            kind: "preflight_grader",
            position: insertion_position + index,
            iteration: step.iteration,
            details: {
              "name" => grader.name,
              "command" => grader.command,
              "phase" => grader.metadata["phase"],
              "configured_phases" => grader.metadata["configured_phases"],
              "legacy_ci_command" => grader.metadata["legacy_ci_command"],
              "legacy_source_grader" => grader.metadata["legacy_source_grader"],
              "description" => grader.description,
              "required" => grader.required,
              "timeout_minutes" => grader.timeout_minutes
            }
          )
        end

        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end

    def materialized_grader_steps
      workflow.steps
        .where(kind: "preflight_grader", iteration: step.iteration)
        .where("position > ?", step.position)
    end
  end
end
