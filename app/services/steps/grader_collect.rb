module Steps
  # Iteration-decision Step. Runs after all per-grader Steps in the
  # loop iteration have completed (succeeded OR failed — graders
  # don't short-circuit each other; they all run regardless). If any
  # *required* grader Step in this iteration ended in `:failed`,
  # this Step raises StepFailed, which the dispatcher recognizes as
  # the loop's iteration signal (see StepDispatcher#fail! handling
  # for grader_collect kind). Otherwise it succeeds and the chain
  # advances past the loop.
  #
  # Aggregating the iteration's results into a single artifact is a
  # convenience for Prompts::GradeFailureFeedback (Phase C) — the
  # prompt can iterate this rollup instead of walking the chain
  # manually. The Step#details on each grader Step remains the
  # source of truth.
  class GraderCollect < Base
    def call
      grader_steps = current_iteration_graders
      carried_forward = carried_forward_grader_entries
      target_health_skipped = target_health_skipped_entries
      append_iteration_results!(grader_steps, carried_forward, target_health_skipped)

      # Carried-forward graders (rerun_only_failed) never appear here — they
      # are, by construction, graders that already passed and so were never
      # candidates for `failed_required` in the first place. Nothing else to
      # merge in for the pass/fail decision.
      failed_required = grader_steps.select do |g|
        g.details && g.details["required"] && g.state == "failed"
      end
      record_grader_loop_metrics!(grader_steps, failed_required: failed_required)
      aggregate_status = GraderConclusionCache.aggregate_status_for(failed_required)
      record_grader_conclusions!(grader_steps, aggregate_status, carried_forward)

      grader_fingerprint = workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY)
      if current_head_sha.present? && (grader_steps.any? || carried_forward.any?)
        log("[grader_collect] grader conclusion cached for #{current_head_sha.first(7)} (fingerprint: #{grader_fingerprint&.first(8)})")
      elsif target_health_skipped.any?
        log("[grader_collect] grader conclusion not cached — all results came from target health records")
      else
        log("[grader_collect] grader conclusion NOT cached — sha=#{current_head_sha.inspect} steps=#{grader_steps.size}")
      end

      if failed_required.empty?
        skipped_count = target_health_skipped.size
        log("[grader_collect] all required graders passed (#{grader_steps.size} grader Step(s) ran, #{skipped_count} target-health skip(s))")
        record_landing_validation!
        return
      end

      return if dismissed_by_rung_zero?(failed_required)

      failed_names = grader_names(failed_required).join(", ")
      log("[grader_collect] required graders failed: #{failed_names}")
      # The same Problem rung 0 just adjudicated, carried on the failure rather
      # than re-derived from this message downstream.
      fail_with!(:grader_failure, "required graders failed: #{failed_names}",
                 evidence: { grader_names: grader_names(failed_required) })
    end

    private

    # Rung 0 of the attention ladder: free, deterministic adjudication before
    # the failure costs anyone anything.
    #
    # Only `inherited_grader_failure` is pre-authorized here, which is exactly
    # what this site already acted on. Other adjudicators still run and their
    # verdicts are still recorded, but acting on one would be a behavior change
    # in when graders are treated as authoritative -- the plan's "an
    # adjudication never applies itself" guardrail.
    def dismissed_by_rung_zero?(failed_required)
      verdict = Adjudicators.call(
        problem: Problem[:grader_failure, evidence: { grader_names: grader_names(failed_required) }],
        workflow: workflow,
        step: failed_required,
        authorized: %w[inherited_grader_failure]
      )
      workflow.set_artifact!("rung_zero_adjudication", verdict.to_h.merge("adjudicated_at" => Time.current.iso8601))
      return false unless verdict.dismiss?

      @inherited_main_failure_evidence = verdict.evidence if verdict.adjudicator == Adjudicators::InheritedGraderFailure.name
      record_inherited_main_failure!(failed_required)
      true
    end

    def grader_names(grader_steps) = grader_steps.map { |grader| grader.details["name"] }

    def record_inherited_main_failure!(failed_required)
      verdict_evidence = @inherited_main_failure_evidence.to_h
      classified = nil
      unless verdict_evidence.key?(:classifications) || verdict_evidence.key?("classifications")
        classified = MainBranchFailureClassifier.call(workflow: workflow, failed_grader_steps: failed_required)
      end
      inherited_names = verdict_evidence[:inherited_names] || verdict_evidence["inherited_names"] || classified&.inherited_names || []
      main_branch_evidence = verdict_evidence[:main_branch_evidence] || verdict_evidence["main_branch_evidence"] || classified&.evidence
      classifications = verdict_evidence[:classifications] || verdict_evidence["classifications"] || classified&.classifications || []
      workflow.set_artifact!("inherited_main_branch_grader_failure", {
        "failed_names" => inherited_names,
        "evidence" => main_branch_evidence,
        "classifications" => classifications,
        "classified_at" => Time.current.iso8601
      })
      log(
        "[grader_collect] required grader failures match broken-main evidence; " \
        "treating as inherited: #{inherited_names.join(', ')}"
      )
    end

    # Grader Steps belonging to this loop iteration, in chain order.
    # When inside a loop/retry_until the loop_id scopes to this exact
    # iteration. Without a loop (e.g. main_grader workflows that run
    # graders once without retrying), fall back to all grader Steps in
    # the workflow — there is only one iteration so no cross-iteration
    # collisions are possible.
    def current_iteration_graders
      if step.loop_id.present?
        workflow.steps
                .where(kind: "grader", loop_id: step.loop_id, iteration: step.iteration)
                .order(:position)
                .to_a
      else
        workflow.steps.where(kind: "grader").order(:position).to_a
      end
    end

    # Graders `Steps::GraderFanout` skipped this iteration because
    # `grade.rerun_only_failed` is on and they already passed last
    # iteration. They have no grader Step of their own this iteration, so
    # their prior PASSED status has to be merged back in here — otherwise a
    # still-passing required grader would silently vanish from this
    # iteration's results instead of continuing to count as passing.
    def carried_forward_grader_entries
      Array(workflow.artifact(GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY))
    end

    def target_health_skipped_entries
      Array(workflow.artifact(GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY))
    end

    # Convenience rollup onto workflow.artifacts["iterations"] for
    # later UI / prompt consumers. Mirrors the structure that
    # Steps::Grade wrote per iteration so existing
    # Prompts::GradeFailureFeedback rendering still works during the
    # transitional period.
    def append_iteration_results!(grader_steps, carried_forward, target_health_skipped)
      iterations = Array(workflow.artifact("iterations"))
      index = run.iteration - 1
      iterations[index] = if grader_steps.empty? && (cache_hit = workflow.artifact(GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY))
        [
          {
            "name" => "cached grader conclusion",
            "required" => true,
            "status" => "passed",
            "cached" => true,
            "commit_sha" => cache_hit["commit_sha"],
            "checked_at" => cache_hit["checked_at"]
          }.compact
        ]
      else
        grader_steps.map do |g|
          details = g.details || {}
          {
            "name" => details["name"],
            "required" => details["required"],
            "status" => g.state == "succeeded" ? "passed" : "failed",
            "exit_code" => details["exit_code"],
            "duration_s" => details["duration_s"],
            "timed_out" => details["timed_out"],
            "log_path" => details["log_path"],
            "log_bytes" => details["log_bytes"],
            "output" => details["output"]
          }
        end + carried_forward.map do |entry|
          {
            "name" => entry["name"],
            "required" => entry["required"],
            "status" => "passed",
            "carried_forward" => true,
            "target_label" => entry["target_label"],
            "target_health_record_refs" => entry["target_health_record_refs"],
            "reason" => entry["reason"],
            "exit_code" => entry["exit_code"],
            "duration_s" => entry["duration_s"],
            "log_path" => entry["log_path"],
            "log_bytes" => entry["log_bytes"],
            "output" => entry["output"]
          }.compact
        end + target_health_skipped.map do |entry|
          {
            "name" => entry["name"],
            "required" => entry["required"],
            "status" => "passed",
            "target_health_skipped" => true,
            "target_label" => entry["target_label"],
            "target_health_record_id" => entry["target_health_record_id"],
            "commit_sha" => entry["commit_sha"],
            "checked_at" => entry["checked_at"],
            "reason" => entry["reason"]
          }.compact
        end
      end
      workflow.set_artifact!("iterations", iterations)
    end

    def record_grader_loop_metrics!(grader_steps, failed_required:)
      timed_steps = grader_steps.select { |g| g.started_at && g.finished_at }
      return if timed_steps.empty?

      started_at = timed_steps.map(&:started_at).min
      finished_at = timed_steps.map(&:finished_at).max
      wall_clock_s = finished_at - started_at
      summed_duration_s = timed_steps.sum do |g|
        duration = g.details.to_h["duration_s"]
        duration.present? ? duration.to_f : (g.finished_at - g.started_at)
      end

      measurements = Array(workflow.artifact("grader_loops"))
      measurements[run.iteration - 1] = {
        "iteration" => run.iteration,
        "grader_count" => grader_steps.size,
        "started_at" => started_at.iso8601,
        "finished_at" => finished_at.iso8601,
        "wall_clock_s" => wall_clock_s.round(3),
        "summed_duration_s" => summed_duration_s.round(3),
        "failed_required_count" => failed_required.size
      }.compact
      measurements[run.iteration - 1].merge!(rollout_metrics_for(grader_steps))
      workflow.set_artifact!("grader_loops", measurements)
      LandingThroughputMetrics.record_grader_loop!(
        workflow: workflow,
        iteration: run.iteration,
        grader_count: grader_steps.size,
        started_at: started_at,
        finished_at: finished_at,
        wall_clock_s: wall_clock_s,
        summed_duration_s: summed_duration_s,
        failed_required_count: failed_required.size,
        rollout_metrics: rollout_metrics_for(grader_steps)
      )

      metrics = rollout_metrics_for(grader_steps)
      log(
        "[grader_collect] grader wall-clock #{wall_clock_s.round(1)}s vs summed duration #{summed_duration_s.round(1)}s; " \
        "worker spread #{metrics.fetch('worker_spread')} worker(s); queue wait avg #{metrics.fetch('queue_wait_avg_s')}s max #{metrics.fetch('queue_wait_max_s')}s; " \
        "prepare cache hits #{metrics.fetch('prepare_cache_hits')} misses #{metrics.fetch('prepare_cache_misses')}; " \
        "infrastructure failures #{metrics.fetch('infrastructure_failure_count')}"
      )
    end

    def rollout_metrics_for(grader_steps)
      @rollout_metrics_for ||= {}
      cache_key = grader_steps.map(&:id)
      @rollout_metrics_for[cache_key] ||= begin
        latest_runs = latest_runs_by_step_id(grader_steps)
        latest_slots = latest_worker_slots_by_step_id(grader_steps)
        waits = grader_steps.filter_map { |grader| queue_wait_s(latest_runs[grader.id]) }
        worker_keys = grader_steps.filter_map { |grader| worker_key_for(grader, latest_slots[grader.id]) }.uniq
        classifications = latest_runs.values.filter_map { |grader_run| grader_run.run_failure_classification&.classification }
        cache_statuses = grader_steps.filter_map { |grader| grader.details.to_h.dig("prepare_cache", "status").presence }

        {
          "queue_wait_avg_s" => rounded_average(waits),
          "queue_wait_max_s" => waits.max&.round(3) || 0.0,
          "worker_spread" => worker_keys.size,
          "worker_keys" => worker_keys,
          "prepare_cache_hits" => cache_statuses.count("hit"),
          "prepare_cache_misses" => cache_statuses.count("miss"),
          "source_snapshot_mismatch_count" => classifications.count("source_snapshot_metadata_invalid"),
          "infrastructure_failure_count" => classifications.count { |classification| infrastructure_failure_classification?(classification) }
        }
      end
    end

    def latest_runs_by_step_id(grader_steps)
      @latest_runs_by_step_id ||= {}
      ids = grader_steps.map(&:id)
      cache_key = ids.sort
      @latest_runs_by_step_id[cache_key] ||= latest_by_step_id(
        Run.where(step_id: ids).includes(:run_failure_classification).order(created_at: :desc, id: :desc)
      )
    end

    def latest_worker_slots_by_step_id(grader_steps)
      @latest_worker_slots_by_step_id ||= {}
      ids = grader_steps.map(&:id)
      cache_key = ids.sort
      @latest_worker_slots_by_step_id[cache_key] ||= latest_by_step_id(
        WorkflowStepWorkerSlot.where(step_id: ids).order(acquired_at: :desc, id: :desc)
      )
    end

    def latest_by_step_id(records)
      records.each_with_object({}) do |record, memo|
        memo[record.step_id] ||= record
      end
    end

    def queue_wait_s(latest_run)
      return unless latest_run&.created_at && latest_run&.started_at

      [ latest_run.started_at - latest_run.created_at, 0 ].max.round(3)
    end

    def worker_key_for(grader, latest_slot)
      latest_slot&.worker_key.presence ||
        grader.details.to_h.dig("immutable_source_checkout", "worker_storage_key").presence
    end

    def infrastructure_failure_classification?(classification)
      classification.to_s.in?(%w[
        source_snapshot_metadata_invalid
        workspace_clone_timeout
        workspace_checkout_invalid
        database_capacity
        database_lock
        disk_full
        worker_died
        worker_died_under_resource_pressure
      ])
    end

    def rounded_average(values)
      return 0.0 if values.empty?

      (values.sum / values.size).round(3)
    end

    def record_grader_conclusions!(grader_steps, aggregate_status, carried_forward)
      return if grader_steps.empty? && carried_forward.empty?

      GraderConclusionCache.record!(
        workflow: workflow,
        run: run,
        step: step,
        commit_sha: current_head_sha,
        grader_steps: grader_steps,
        aggregate_status: aggregate_status,
        grader_fingerprint: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY),
        carried_forward: carried_forward
      )
    end

    def record_landing_validation!
      return if workflow.trigger_kind == "main_grader"

      head_sha = current_head_sha
      base_sha = landing_base_sha
      base_ref = landing_base_ref
      return if head_sha.blank?

      LandingValidationCache.record!(
        workflow: workflow,
        head_sha: head_sha,
        tree_sha: current_tree_sha,
        base_sha: base_sha,
        base_tree_sha: landing_base_tree_sha,
        base_ref: base_ref,
        grader_fingerprint: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY),
        changed_files_fingerprint: workflow.artifact("grade_plan_changed_files_fingerprint"),
        validation_source: landing_validation_source
      )
      LandingValidationPrefetcher.after_landing_graders_passed(workflow: workflow) if landing_validation_prefetch_source?
    rescue StandardError => e
      Rails.logger.warn("[GraderCollect] landing validation capture failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      nil
    end

    def landing_base_sha
      return workflow.artifact("predicted_base_sha").presence if landing_validation_child?
      return job.mergeability_base_sha.presence if workflow.trigger_kind == "auto_merge"
      return workflow.artifact("merge_train_base_sha").presence if workflow.trigger_kind == "merge_train"

      GitRunner.new.run("rev-parse", default_branch_ref, chdir: workspace.path.to_s).strip.presence
    end

    def landing_base_ref
      return workflow.artifact("predicted_base_ref").presence if landing_validation_child?
      return job.mergeability_base_ref.presence if workflow.trigger_kind == "auto_merge"
      return merge_train_base_ref if workflow.trigger_kind == "merge_train"

      job.effective_base_branch.presence
    end

    def merge_train_base_ref
      id = workflow.artifact("merge_train_id")
      return nil if id.blank?

      MergeTrain.find_by(id: id)&.base_branch.presence
    end

    def landing_base_tree_sha
      return workflow.artifact("predicted_base_tree_sha").presence if landing_validation_child?

      nil
    end

    def landing_validation_source
      landing_validation_child? ? "speculative_landing" : "graders"
    end

    def landing_validation_prefetch_source?
      workflow.work_definition.landing_validation_prefetch_source?
    end

    def landing_validation_child?
      workflow.work_definition.landing_validation_child?
    end

    def current_head_sha
      return @current_head_sha if defined?(@current_head_sha)

      @current_head_sha =
        workflow.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY).presence ||
        GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      Rails.logger.warn("[GraderCollect] current HEAD capture failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      @current_head_sha = nil
    end

    def current_tree_sha
      return @current_tree_sha if defined?(@current_tree_sha)

      @current_tree_sha = GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      Rails.logger.warn("[GraderCollect] current tree capture failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      @current_tree_sha = nil
    end
  end
end
