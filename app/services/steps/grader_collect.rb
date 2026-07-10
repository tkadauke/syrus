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
      iterations[index] = grader_steps.map do |g|
        details = g.details || {}
        {
          "name" => details["name"],
          "required" => details["required"],
          "status" => g.state == "succeeded" ? "passed" : "failed",
          "exit_code" => details["exit_code"],
          "duration_s" => details["duration_s"],
          "log_path" => details["log_path"],
          "log_bytes" => details["log_bytes"],
          "output" => details["output"]
        }
      end
      workflow.set_artifact!("iterations", iterations)
    end

    def record_landing_validation!
      return if workflow.trigger_kind == "main_grader"

      head_sha = GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      base_sha = workflow.trigger_kind == "auto_merge" ? job.mergeability_base_sha.presence : nil
      base_ref = workflow.trigger_kind == "auto_merge" ? job.mergeability_base_ref.presence : nil
      return if head_sha.blank?

      LandingValidationCache.record!(
        workflow: workflow,
        head_sha: head_sha,
        base_sha: base_sha,
        base_ref: base_ref
      )
    rescue StandardError => e
      Rails.logger.warn("[GraderCollect] landing validation capture failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
