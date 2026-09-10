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
      grader_fingerprint = GraderConclusionCache.fingerprint_for_plan(plan, target_graph: target_graph)

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
        source_snapshot = current_source_snapshot_for_projection

        workflow.steps.where("position >= ?", insertion_position).update_all(
          [ "position = position + ?", offset ]
        )

        new_steps = graders.each_with_index.map do |grader, index|
          prepare_targets = prepare_targets_for(grader)

          Step.create!(
            workflow: workflow,
            kind: "preflight_grader",
            position: insertion_position + index,
            iteration: step.iteration,
            placement_policy: Step::Kind.fetch("preflight_grader").placement_policy_for(repository),
            details: grader_details(grader, prepare_targets: prepare_targets).merge(distributed_grader_details(grader, source_snapshot: source_snapshot))
          )
        end

        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end

    def grader_details(grader, prepare_targets:)
      {
        "name" => grader.name,
        "target_label" => target_label_for(grader),
        "command" => grader.command,
        "phase" => grader.metadata["phase"],
        "configured_phases" => grader.metadata["configured_phases"],
        "legacy_ci_command" => grader.metadata["legacy_ci_command"],
        "legacy_source_grader" => grader.metadata["legacy_source_grader"],
        "description" => grader.description,
        "required" => grader.required,
        "timeout_minutes" => grader.timeout_minutes,
        "prepare_targets" => prepare_targets,
        "prepare_commands" => prepare_targets.flat_map { |target| target["commands"] }
      }
    end

    def distributed_grader_details(grader, source_snapshot:)
      return {} unless Feature.distributed_workflow_dag_enabled?(repository)

      {
        "projected_target_label" => "//:preflight-grade/#{grader.name}",
        "barrier_labels" => [ "preflight_grader_collect" ],
        "source_snapshot_id" => source_snapshot.id,
        "source_snapshot" => {
          "id" => source_snapshot.id,
          "source_sha" => source_snapshot.source_sha,
          "source_ref" => source_snapshot.source_ref,
          "tree_sha" => source_snapshot.tree_sha,
          "fingerprint" => source_snapshot.fingerprint
        }.compact
      }
    end

    def current_source_snapshot_for_projection
      return nil unless Feature.distributed_workflow_dag_enabled?(repository)

      source_sha = current_head_sha.presence
      tree_sha = current_tree_sha.presence
      source_ref = current_source_ref
      unless source_sha && tree_sha
        raise WorkflowSourceSnapshots::InfrastructureStateError, "workflow source snapshot metadata missing: current checkout identity"
      end

      current = WorkflowSourceSnapshots.current_for(workflow)
      return current if current&.source_sha == source_sha && current&.tree_sha == tree_sha && current&.source_ref == source_ref

      WorkflowSourceSnapshots.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: source_sha,
        source_ref: source_ref,
        tree_sha: tree_sha
      )
    end

    def current_head_sha
      GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("[preflight_grader_fanout] could not read current HEAD for source snapshot metadata: #{e.message}")
      nil
    end

    def current_tree_sha
      GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("[preflight_grader_fanout] could not read current tree for source snapshot metadata: #{e.message}")
      nil
    end

    def current_source_ref
      branch_name = workspace.respond_to?(:branch_name) ? workspace.branch_name.to_s.presence : nil
      branch_name ? "refs/heads/#{branch_name}" : "HEAD"
    end

    def materialized_grader_steps
      workflow.steps
        .where(kind: "preflight_grader", iteration: step.iteration)
        .where("position > ?", step.position)
    end

    def prepare_targets_for(grader)
      target_graph.prepare_dependencies_for(target_label_for(grader)).map do |target|
        project_path = target_graph.project(target.project_id)&.path.to_s
        {
          "target_label" => target.label.to_s,
          "commands" => Array(target.metadata.fetch("commands") { [ target.command ] }).flatten.map(&:to_s)
        }.tap do |payload|
          payload["project_path"] = project_path if project_path.present?
        end
      end
    end

    def target_label_for(grader)
      "//:grade/#{grader.name}"
    end

    def target_graph
      @target_graph ||= TargetGraph::Compiler.compile(workspace.path)
    end
  end
end
