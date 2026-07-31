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
      append_iteration_results!(grader_steps)

      failed_required = grader_steps.select do |g|
        g.details && g.details["required"] && g.state == "failed"
      end
      aggregate_status = GraderConclusionCache.aggregate_status_for(failed_required)
      record_grader_conclusions!(grader_steps, aggregate_status)

      grader_fingerprint = workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY)
      if current_head_sha.present? && grader_steps.any?
        log("[grader_collect] grader conclusion cached for #{current_head_sha.first(7)} (fingerprint: #{grader_fingerprint&.first(8)})")
      else
        log("[grader_collect] grader conclusion NOT cached — sha=#{current_head_sha.inspect} steps=#{grader_steps.size}")
      end

      if failed_required.empty?
        log("[grader_collect] all required graders passed (#{grader_steps.size} grader Step(s) ran)")
        record_landing_validation!
        return
      end

      failed_names = failed_required.map { |g| g.details["name"] }.join(", ")
      log("[grader_collect] required graders failed: #{failed_names}")
      raise Base::StepFailed, "required graders failed: #{failed_names}"
    end

    private

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

    # Convenience rollup onto workflow.artifacts["iterations"] for
    # later UI / prompt consumers. Mirrors the structure that
    # Steps::Grade wrote per iteration so existing
    # Prompts::GradeFailureFeedback rendering still works during the
    # transitional period.
    def append_iteration_results!(grader_steps)
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
        end
      end
      workflow.set_artifact!("iterations", iterations)
    end

    def record_grader_conclusions!(grader_steps, aggregate_status)
      return if grader_steps.empty?

      GraderConclusionCache.record!(
        workflow: workflow,
        run: run,
        step: step,
        commit_sha: current_head_sha,
        grader_steps: grader_steps,
        aggregate_status: aggregate_status,
        grader_fingerprint: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY)
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
        base_ref: base_ref,
        grader_fingerprint: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY)
      )
    rescue StandardError => e
      Rails.logger.warn("[GraderCollect] landing validation capture failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      nil
    end

    def landing_base_sha
      return job.mergeability_base_sha.presence if workflow.trigger_kind == "auto_merge"
      return workflow.artifact("merge_train_base_sha").presence if workflow.trigger_kind == "merge_train"

      nil
    end

    def landing_base_ref
      return job.mergeability_base_ref.presence if workflow.trigger_kind == "auto_merge"
      return merge_train_base_ref if workflow.trigger_kind == "merge_train"

      nil
    end

    def merge_train_base_ref
      id = workflow.artifact("merge_train_id")
      return nil if id.blank?

      MergeTrain.find_by(id: id)&.base_branch.presence
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
