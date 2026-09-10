require "digest"

module Steps
  # Materializes per-grader Steps from .syrus.yml. Runs after each
  # `implement` (or equivalent) Step inside the workflow's grade
  # loop; inserts one `grader` Step per configured grader between
  # itself and the next Step in the chain (which is the
  # `grader_collect` Step that aggregates the iteration's outcome).
  #
  # Why this exists: the chain is built at workflow-instantiate
  # time, before the workspace exists. The list of graders comes
  # from `.syrus.yml` in the cloned repo, which is only readable
  # AFTER Steps::Prepare runs. So the static chain has a placeholder
  # `grader_fanout` Step that, at execution time, reads the plan
  # and dynamically inserts the actual graders. Each grader Step's
  # definition (name, command, description, required, timeout)
  # is snapshotted onto its Step#details — immutable for that Step,
  # immune to `.syrus.yml` evolution.
  class GraderFanout < Base
    # Written every fanout call (including early-return paths) so
    # Steps::GraderCollect always sees a value scoped to *this* iteration,
    # never a stale entry left over from an earlier one.
    CARRIED_FORWARD_ARTIFACT_KEY = "grade_carried_forward_graders".freeze
    MATERIALIZATION_LOCK_ERRORS = [
      ActiveRecord::Deadlocked,
      ActiveRecord::LockWaitTimeout
    ].freeze
    MATERIALIZATION_LOCK_RETRY_ATTEMPTS = 3
    TARGET_HEALTH_SKIPS_ARTIFACT_KEY = "target_health_skipped_targets".freeze

    def call
      workspace.setup
      workflow.set_artifact!(CARRIED_FORWARD_ARTIFACT_KEY, [])
      workflow.set_artifact!(TARGET_HEALTH_SKIPS_ARTIFACT_KEY, [])
      plan = effective_plan(RepoGradePlan.for(workspace.path))
      grader_fingerprint = GraderConclusionCache.fingerprint_for_plan(plan, target_graph: target_graph)
      record_plan_source!(plan, grader_fingerprint)
      apply_loop_max_iterations!(plan.max_iterations)

      log("[grader_fanout] source: #{plan.source}")
      log("[grader_fanout] note: #{plan.note}") if plan.note

      if plan.graders.empty?
        log("[grader_fanout] no graders configured — collect Step will pass through")
        return
      end
      log("[grader_fanout] using #{grader_phase} grader phase") unless review_grader_context?

      # Skip graders whose target isn't affected by this PR's diff -- own
      # source scope (when_files_changed) or, transitively, a declared
      # dependency's source scope (TargetGraph#affected).
      files = changed_files
      record_changed_files!(files)
      matching_files = matching_files_for(files)
      selections = plan.graders.map { |g| [ g, target_graph.affected(target_label_for(g), changed_files: matching_files) ] }
      active_graders = selections.select { |(_g, selection)| selection.affected }.map(&:first)
      log_selections(selections)

      if plan.rerun_only_failed? && step.iteration > 1
        passed_steps_by_name = previous_iteration_passed_steps_by_name
        active_graders, carried_forward = active_graders.partition { |g| !passed_steps_by_name.key?(g.name) }
        if carried_forward.any?
          carried_forward.each { |g| log("[grader_fanout] skipping #{g.name} (passed iteration #{step.iteration - 1}; rerun_only_failed)") }
          record_carried_forward_graders!(carried_forward, passed_steps_by_name)
        end
      end

      active_graders = skip_reusable_target_health!(active_graders)

      if active_graders.empty?
        log("[grader_fanout] all graders skipped — collect Step will pass through")
        return
      end

      # A recorded success for this exact head SHA + grader set short-circuits
      # the re-run. Safe alongside the skip above: the fingerprint is the full
      # plan, so a full-plan success implies the active subset would pass too.
      if (cache_hit = reusable_success(grader_fingerprint))
        workflow.set_artifact!(
          GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY,
          {
            "commit_sha" => cache_hit.commit_sha,
            "grader_fingerprint" => cache_hit.grader_fingerprint,
            "checked_at" => cache_hit.checked_at&.iso8601,
            "conclusion_id" => cache_hit.id
          }.compact
        )
        log("[grader_fanout] reused successful grader conclusion for #{cache_hit.commit_sha.first(7)} - collect Step will pass through")
        return
      end

      if materialized_grader_steps.exists?
        log("[grader_fanout] grader Steps already materialized for iteration #{step.iteration}; reusing existing Step chain")
        return
      end

      materialize_grader_steps!(active_graders)
      log("[grader_fanout] materialized #{active_graders.size} grader Step(s)")
    end

    private

    def changed_files
      GitRunner.new.run("diff", "--name-only", "#{changed_files_base_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[grader_fanout] warning: could not determine changed files: #{e.message}")
      []
    end

    def changed_files_base_ref
      return workflow.artifact("predicted_base_sha").presence if workflow.work_definition.landing_validation_child?

      default_branch_ref
    end

    # Explains every grader's selection/skip by name and target label -- the
    # existing "skipped <name> (no matching files changed)" prefix is kept
    # verbatim so it stays a stable substring for anything already grepping
    # workflow logs; the target label is appended rather than interleaved.
    def log_selections(selections)
      selections.each do |grader, selection|
        verb = selection.affected ? "selected" : "skipped"
        log("[grader_fanout] #{verb} #{grader.name} (#{selection.reason}) [#{target_label_for(grader)}]")
      end
    end

    # Expands the raw diff's changed files with any :affected_test_analyzer
    # answers before when_files_changed matching. This set is ONLY used for
    # the match decision below — never for record_changed_files!, which must
    # stay a literal diff so its fingerprint stays comparable with the plain
    # `git diff --name-only` fingerprints other landing-validation-cache call
    # sites compute. Strictly additive: a registered analyzer can only turn a
    # would-be skip into a run, never the reverse, so an unregistered,
    # declining, or erroring analyzer leaves matching identical to glob-only
    # behavior against the raw diff.
    def matching_files_for(files)
      return files if files.empty?

      extra = affected_test_files(files)
      extra.empty? ? files : (files + extra).uniq
    end

    def affected_test_files(files)
      Syrus::PluginRegistry.providers_for(:affected_test_analyzer).flat_map do |analyzer|
        begin
          result = analyzer.affected_files(repo_path: workspace.path.to_s, changed_files: files)
          if result.nil?
            log("[grader_fanout] #{analyzer} declined to analyze this diff — falling back to glob-only for it")
            []
          else
            log("[grader_fanout] #{analyzer} reports #{result.size} additional affected file(s)") if result.any?
            Array(result)
          end
        rescue StandardError => e
          log("[grader_fanout] affected_test_analyzer #{analyzer} raised #{e.class}: #{e.message} — falling back to glob-only for it")
          []
        end
      end.uniq
    end

    # Graders that succeeded on the immediately preceding iteration, keyed by
    # name. `rerun_only_failed` only looks back one iteration (not the full
    # history) — a grader that was itself carried-forward (and so has no Step
    # of its own) in iteration N-1 is treated as needing a fresh run in
    # iteration N. That is a safe, self-correcting fallback (it just reruns
    # a grader that might still be green) rather than a correctness bug.
    def previous_iteration_passed_steps_by_name
      return {} if step.loop_id.blank?

      workflow.steps
              .where(kind: "grader", loop_id: step.loop_id, iteration: step.iteration - 1, state: "succeeded")
              .filter_map { |s| [ s.details && s.details["name"], s ] if s.details && s.details["name"] }
              .to_h
    end

    # Snapshots enough of the prior passing grader Step's details for
    # Steps::GraderCollect to both report it in this iteration's results and
    # record a per-iteration GraderConclusion for it, without re-querying
    # Steps itself.
    def record_carried_forward_graders!(carried_forward, passed_steps_by_name)
      entries = carried_forward.map do |g|
        prior_details = passed_steps_by_name[g.name]&.details || {}
        {
          "name" => g.name,
          "required" => g.required,
          "source_iteration" => step.iteration - 1,
          "exit_code" => prior_details["exit_code"],
          "duration_s" => prior_details["duration_s"],
          "log_path" => prior_details["log_path"],
          "log_bytes" => prior_details["log_bytes"],
          "output" => prior_details["output"]
        }.compact
      end
      workflow.set_artifact!(CARRIED_FORWARD_ARTIFACT_KEY, entries)
    end

    def skip_reusable_target_health!(graders)
      skipped = []
      remaining = graders.reject do |grader|
        result = target_health_reuse.for_target(target_label_for(grader))
        if result.reusable?
          skipped << skipped_target_health_entry(grader, result)
          true
        else
          log("[grader_fanout] target health miss for #{grader.name}: #{result.reason} [#{target_label_for(grader)}]")
          false
        end
      end

      record_target_health_skips!(skipped) if skipped.any?
      remaining
    end

    def skipped_target_health_entry(grader, result)
      ref = result.record_refs.first || {}
      {
        "name" => grader.name,
        "required" => grader.required,
        "target_label" => target_label_for(grader),
        "reason" => result.reason,
        "target_health_record_refs" => result.record_refs
      }.merge(ref.slice("target_health_record_id", "commit_sha", "checked_at")).compact
    end

    def record_target_health_skips!(entries)
      entries.each do |entry|
        commit = entry["commit_sha"].to_s.first(7).presence || "unknown commit"
        log("[grader_fanout] skipped #{entry['name']} (#{entry['reason']} from #{commit}) [#{entry['target_label']}]")
      end
      workflow.set_artifact!(TARGET_HEALTH_SKIPS_ARTIFACT_KEY, entries)
      step.update!(details: step.details.to_h.merge(TARGET_HEALTH_SKIPS_ARTIFACT_KEY => entries))
    end

    def record_plan_source!(plan, grader_fingerprint)
      workflow.set_artifact!("grade_plan_source", plan.source)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, grader_fingerprint)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, current_head_sha)
    end

    def record_changed_files!(files)
      normalized = Array(files).map(&:to_s).sort
      workflow.set_artifact!("grade_plan_changed_files", normalized)
      workflow.set_artifact!("grade_plan_changed_files_fingerprint", LandingValidationCache.changed_files_fingerprint(normalized))
    end

    def reusable_success(grader_fingerprint)
      head_sha = current_head_sha
      return nil if head_sha.blank?

      GraderConclusionCache.latest_success(
        repository: repository,
        commit_sha: head_sha,
        grader_fingerprint: grader_fingerprint
      )
    end

    def current_head_sha
      GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("[grader_fanout] could not read current HEAD for grader conclusion cache: #{e.message}")
      nil
    end

    def apply_loop_max_iterations!(max_iterations)
      loop_node = Array(workflow.chain_template).find { |node| loop_node_for_current_step?(node) }
      return unless loop_node

      workflow.extend_chain! do |template|
        template.find { |node| loop_node_for_current_step?(node) }["max_iterations"] = max_iterations
      end
    end

    def loop_node_for_current_step?(node)
      case node["type"]
      when "loop"
        Array(node["steps"]).map(&:to_s).include?(step.kind)
      when "retry_until"
        (Array(node["repair"]).map(&:to_s) + Array(node["check"]).map(&:to_s)).include?(step.kind)
      else
        false
      end
    end

    # Insert one Step per grader between this fanout Step and its
    # current next_step (which is the iteration's grader_collect).
    # Bump positions of everything past the insertion point to
    # make room.
    def materialize_grader_steps!(graders)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = graders.size

      with_materialization_lock_retries do
        Step.transaction do
          source_snapshot = current_source_snapshot_for_projection

          workflow.steps.where("position >= ?", insertion_position).update_all(
            [ "position = position + ?", offset ]
          )

          new_steps = graders.each_with_index.map do |grader, index|
            prepare_targets = prepare_targets_for(grader)
            target_fingerprints = target_fingerprints_for(grader)

            Step.create!(
              workflow: workflow,
              kind: "grader",
              position: insertion_position + index,
              iteration: step.iteration,
              loop_id: step.loop_id,
              placement_policy: grader_placement_policy,
              details: grader_details(grader, prepare_targets: prepare_targets, target_fingerprints: target_fingerprints)
                .merge(distributed_grader_details(grader, source_snapshot: source_snapshot, target_fingerprints: target_fingerprints))
            )
          end

          link_materialized_grader_steps!(new_steps, continuation)

          # workflow-engine-v3 A5: the graders all run from this fanout, and the
          # continuation waits for every one of them. Stating the fan-in as edges
          # is what lets "find next" be a ready-set query instead of a sentinel
          # plus a per-kind waits_for_terminal_step_kind rule.
          new_steps.each { |grader| grader.update!(depends_on_ids: [ step.id ]) }
          continuation&.update!(depends_on_ids: new_steps.map(&:id))
        end
      end
    end

    def with_materialization_lock_retries
      attempts = 0

      begin
        yield
      rescue *MATERIALIZATION_LOCK_ERRORS => e
        attempts += 1
        raise if attempts > MATERIALIZATION_LOCK_RETRY_ATTEMPTS

        log("[grader_fanout] transient step materialization lock conflict (#{e.class}); retrying #{attempts}/#{MATERIALIZATION_LOCK_RETRY_ATTEMPTS}")
        sleep(0.05 * attempts) unless Rails.env.test?
        retry
      end
    end

    def link_materialized_grader_steps!(new_steps, continuation)
      if distributed_parallel_grader_projection_enabled?
        step.update!(next_step_id: new_steps.first&.id || continuation&.id)
        new_steps.each { |grader| grader.update!(next_step_id: continuation&.id) }
      else
        # Gate-off workflows preserve the legacy linked-list shape: graders run
        # one after another, then the original continuation collects them.
        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
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
        "description" => grader.description,
        "required" => grader.required,
        "timeout_minutes" => grader.timeout_minutes,
        "when_files_changed" => grader.when_files_changed,
        "prepare_targets" => prepare_targets,
        "prepare_commands" => prepare_targets.flat_map { |target| target["commands"] },
        "junit_output" => grader.junit_output,
        "failures" => grader.failures,
        "target_fingerprints" => target_fingerprints.to_h
      }
    end

    def distributed_grader_details(grader, source_snapshot:, target_fingerprints:)
      return {} unless distributed_grader_projection_enabled?

      target_label = "//:grade/#{grader.name}"

      {
        "projected_target_label" => target_label,
        "projected_target_fingerprint" => target_fingerprints.command_fingerprint,
        "projected_resource_key" => "target:#{target_label}",
        "barrier_group" => grader_barrier_group,
        "barrier_labels" => [ "grader_collect" ],
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
      unless source_sha && tree_sha
        raise WorkflowSourceSnapshots::InfrastructureStateError, "workflow source snapshot metadata missing: current checkout identity"
      end
      source_ref = current_source_ref(source_sha)

      current = WorkflowSourceSnapshots.current_for(workflow)
      if current&.source_sha == source_sha && current&.tree_sha == tree_sha && current&.source_ref == source_ref
        log("[grader_fanout] verified existing source snapshot ##{current.id} for #{source_sha.first(7)}")
        return current
      end

      snapshot = WorkflowSourceSnapshots.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: source_sha,
        source_ref: source_ref,
        tree_sha: tree_sha
      )
      log("[grader_fanout] recorded source snapshot ##{snapshot.id} #{source_ref}@#{source_sha.first(7)}")
      snapshot
    end

    def current_tree_sha
      return @current_tree_sha if defined?(@current_tree_sha)

      @current_tree_sha = GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("[grader_fanout] could not read current tree for source snapshot metadata: #{e.message}")
      @current_tree_sha = nil
    end

    def current_source_ref(source_sha)
      checkpoint_ref_for(source_sha) || publish_source_snapshot_ref!(source_sha)
    end

    def checkpoint_ref_for(source_sha)
      RunCheckpoint.published
        .where(workflow: workflow, commit_sha: source_sha)
        .recent
        .first
        &.remote_ref
    end

    def publish_source_snapshot_ref!(source_sha)
      remote_ref = "refs/syrus/source-snapshots/runs/#{run.id}"
      log("[grader_fanout] publishing source snapshot #{source_sha.first(7)} to #{remote_ref}")
      authenticated_git("git_workflow_source_snapshot_push") do |url|
        GitRunner.new.run(
          "push",
          url,
          "#{source_sha}:#{remote_ref}",
          chdir: workspace.path.to_s,
          env: { "GIT_TERMINAL_PROMPT" => "0" }
        )
      end
      log("[grader_fanout] published source snapshot #{source_sha.first(7)} to #{remote_ref}")
      remote_ref
    rescue GitRunner::GitError => e
      raise WorkflowSourceSnapshots::InfrastructureStateError,
            "workflow source snapshot ref publish failed for #{source_sha}: #{e.message}"
    end

    def grader_barrier_group
      [ "workflow", workflow.id, "loop", step.loop_id.presence || "none", "iteration", step.iteration, "grader_collect" ].join(":")
    end

    def distributed_grader_projection_enabled?
      Feature.distributed_workflow_dag_enabled?(repository) && WorkflowStepWorkerSlot.enabled?
    end

    def distributed_parallel_grader_projection_enabled?
      distributed_grader_projection_enabled?
    end

    def grader_placement_policy
      return Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE unless distributed_grader_projection_enabled?

      Step::Kind.fetch("grader").placement_policy_for(repository)
    end

    def materialized_grader_steps
      workflow.steps
        .where(kind: "grader", iteration: step.iteration, loop_id: step.loop_id)
        .where("position > ?", step.position)
    end

    def effective_plan(plan)
      LandingGraderPlan.effective(plan, trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end

    # One entry per transitive `kind: prepare` dependency target, in
    # dependency order -- Steps::Grader (via PrepareTargetExecution) runs
    # each of these at most once per workflow workspace before the grader
    # command itself.
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

    def target_health_reuse
      @target_health_reuse ||= TargetHealthReuse.new(
        repository: repository,
        graph: target_graph,
        workspace_path: workspace.path
      )
    end

    def target_label_for(grader)
      "//:grade/#{grader.name}"
    end

    def target_graph
      return @target_graph if defined?(@target_graph)

      @target_graph = TargetGraph::Compiler.compile(workspace.path)
    end

    def review_grader_context?
      grader_phase == :review
    end

    def grader_phase
      LandingGraderPlan.phase_for(trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end
  end
end
