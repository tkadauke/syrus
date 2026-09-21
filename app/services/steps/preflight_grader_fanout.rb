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
    MATERIALIZATION_LOCK_ERRORS = [
      ActiveRecord::Deadlocked,
      ActiveRecord::LockWaitTimeout
    ].freeze
    MATERIALIZATION_LOCK_RETRY_ATTEMPTS = 3

    def call
      workspace.setup
      plan = effective_plan(graph_grade_plan)
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

      if materialize_grader_steps!(plan.graders)
        log("[preflight_grader_fanout] materialized #{plan.graders.size} grader step(s)")
      end
    end

    private

    def effective_plan(plan)
      LandingGraderPlan.effective(plan, trigger_kind: workflow.trigger_kind, iteration: 1)
    end

    def graph_grade_plan
      TargetGraph::GradePlan.for(workspace_path: workspace.path, graph: target_graph)
    end

    def materialize_grader_steps!(graders)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = graders.size
      source_snapshot = nil
      materialized = false

      return false unless continue_side_effects?("[preflight_grader_fanout] materialization")

      with_materialization_lock_retries do
        heartbeat!
        Step.transaction do
          unless continue_side_effects?("[preflight_grader_fanout] materialization")
            source_snapshot = nil
            next
          end

          source_snapshot = current_source_snapshot_for_projection
          heartbeat!

          workflow.steps.where("position >= ?", insertion_position).update_all(
            [ "position = position + ?", offset ]
          )
          heartbeat!

          new_steps = graders.each_with_index.map do |grader, index|
            heartbeat! if (index % 5).zero?
            prepare_targets = prepare_targets_for(grader)
            target_fingerprints = target_fingerprints_for(grader)

            Step.create!(
              workflow: workflow,
              kind: "preflight_grader",
              position: insertion_position + index,
              iteration: step.iteration,
              placement_policy: grader_placement_policy,
              details: grader_details(grader, prepare_targets: prepare_targets, target_fingerprints: target_fingerprints)
                .merge(distributed_grader_details(grader, source_snapshot: source_snapshot, target_fingerprints: target_fingerprints))
            )
          end

          link_materialized_grader_steps!(new_steps, continuation)

          # The graders all run from this fanout and the continuation waits for
          # every one of them. Stating that as edges is what makes them
          # *parallel*: with no edges, Step#dependencies_settled? falls back to
          # the linked-list predecessor, so grader N waits on grader N-1 and the
          # batch runs single-file no matter what the placement policy or the
          # Solid Queue concurrency key allow (WF-28163 ran 14 of them one at a
          # time, ~1s apart, with the distributed gate fully on).
          new_steps.each { |grader| grader.update!(depends_on_ids: [ step.id ]) }
          continuation&.update!(depends_on_ids: new_steps.map(&:id))
          materialized = true
        end
      end

      if source_snapshot
        return true unless continue_side_effects?("[preflight_grader_fanout] source snapshot publication")

        heartbeat!
        publish_prepared_workspace_archive!(source_snapshot)
        heartbeat!
      end

      materialized
    end

    def link_materialized_grader_steps!(new_steps, continuation)
      if distributed_parallel_grader_projection_enabled?
        step.update!(next_step_id: new_steps.first&.id || continuation&.id)
        new_steps.each { |grader| grader.update!(next_step_id: continuation&.id) }
      else
        # Gate-off workflows keep the legacy linked-list shape: graders run one
        # after another, then the continuation collects them.
        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end

    def with_materialization_lock_retries
      attempts = 0

      begin
        yield
      rescue *MATERIALIZATION_LOCK_ERRORS => e
        attempts += 1
        raise if attempts > MATERIALIZATION_LOCK_RETRY_ATTEMPTS

        log("[preflight_grader_fanout] transient step materialization lock conflict (#{e.class}); retrying #{attempts}/#{MATERIALIZATION_LOCK_RETRY_ATTEMPTS}")
        sleep(0.05 * attempts) unless Rails.env.test?
        retry
      end
    end

    def grader_details(grader, prepare_targets:, target_fingerprints:)
      {
        "name" => grader.name,
        "target_label" => target_label_for(grader),
        "command" => grader.command,
        "phase" => grader.metadata["phase"],
        "configured_phases" => grader.metadata["configured_phases"],
        "legacy_ci_command" => grader.metadata["legacy_ci_command"],
        "legacy_source_grader" => grader.metadata["legacy_source_grader"],
        "grader_type" => grader.metadata["grader_type"],
        "grader_framework" => grader.metadata["grader_framework"],
        "grader_mode" => grader.metadata["grader_mode"],
        "coverage_outputs" => grader.metadata["coverage_outputs"],
        "result_outputs" => grader.metadata["result_outputs"],
        "filter_capabilities" => grader.metadata["filter_capabilities"],
        "description" => grader.description,
        "required" => grader.required,
        "timeout_minutes" => grader.timeout_minutes,
        "prepare_targets" => prepare_targets,
        "prepare_commands" => prepare_targets.flat_map { |target| target["commands"] },
        "target_fingerprints" => target_fingerprints.to_h
      }
    end

    def distributed_grader_details(grader, source_snapshot:, target_fingerprints:)
      return {} unless distributed_grader_projection_enabled?

      {
        "projected_target_label" => target_label_for(grader),
        "projected_target_fingerprint" => target_fingerprints.command_fingerprint,
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
      return nil unless distributed_grader_projection_enabled?

      source_sha = current_head_sha.presence
      tree_sha = current_tree_sha.presence
      source_ref = current_source_ref
      unless source_sha && tree_sha
        raise WorkflowSourceSnapshots::InfrastructureStateError, "workflow source snapshot metadata missing: current checkout identity"
      end

      current = WorkflowSourceSnapshots.current_for(workflow)
      if current&.source_sha == source_sha && current&.tree_sha == tree_sha && current&.source_ref == source_ref
        log("[preflight_grader_fanout] verified existing source snapshot ##{current.id} for #{source_sha.first(7)}")
        return current
      end

      snapshot = WorkflowSourceSnapshots.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: source_sha,
        source_ref: source_ref,
        tree_sha: tree_sha
      )
      log("[preflight_grader_fanout] recorded source snapshot ##{snapshot.id} #{source_ref}@#{source_sha.first(7)}")
      snapshot
    end

    def publish_prepared_workspace_archive!(source_snapshot)
      plan = RepoPrepPlan.for(workspace.path)
      unless prepared_workspace_matches_current_plan?(plan)
        log("[preflight_grader_fanout] prepared workspace archive skipped; prepare output does not match current plan")
        return false
      end

      PreparedWorkspaceArchive.publish!(
        workflow: workflow,
        snapshot: source_snapshot,
        step: step,
        path: workspace.path,
        plan: plan,
        log: ->(message, **_kwargs) { log(message) }
      )
    end

    def prepared_workspace_matches_current_plan?(plan)
      fresh_workflow = workflow.reload
      prepared = fresh_workflow.artifact("prepared_workspace").to_h
      return false if fresh_workflow.artifact("prepare_failure").present?

      prepared["prepare_fingerprint"] == PreparedWorkspaceArchive.prepare_fingerprint_for(plan)
    end

    def distributed_grader_projection_enabled?
      Feature.distributed_workflow_dag_enabled?(repository)
    end

    def distributed_parallel_grader_projection_enabled?
      distributed_grader_projection_enabled?
    end

    def grader_placement_policy
      return Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE unless distributed_grader_projection_enabled?

      Step::Kind.fetch("preflight_grader").placement_policy_for(repository)
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
      return current_base_source_ref if workflow.trigger_kind == "main_branch_repair" && unpublished_repair_branch?

      branch_name = workspace.respond_to?(:branch_name) ? workspace.branch_name.to_s.presence : nil
      branch_name ? "refs/heads/#{branch_name}" : "HEAD"
    end

    def unpublished_repair_branch?
      job.pr_number.blank? && job.fork_review_pr_number.blank?
    end

    def current_base_source_ref
      base_ref = workspace.respond_to?(:base_ref) ? workspace.base_ref.to_s.presence : nil
      return "HEAD" if base_ref.blank?

      branch = base_ref.delete_prefix("origin/")
      "refs/heads/#{branch}"
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

    def target_fingerprints_for(grader)
      TargetGraph::Fingerprints.for_target(
        workspace_path: workspace.path,
        graph: target_graph,
        label: target_label_for(grader)
      )
    end

    def target_label_for(grader)
      grader.metadata["target_label"].presence || "//:grade/#{grader.name}"
    end

    def target_graph
      @target_graph ||= TargetGraph::Compiler.compile(workspace.path)
    end
  end
end
