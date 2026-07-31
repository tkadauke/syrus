require "digest"

class GraderConclusionCache
  ARTIFACT_FINGERPRINT_KEY = "grade_plan_fingerprint".freeze
  ARTIFACT_CACHE_HIT_KEY = "grader_conclusion_cache_hit".freeze
  ARTIFACT_HEAD_SHA_KEY = "grade_plan_head_sha".freeze

  def self.fingerprint_for_plan(plan)
    fingerprint_for_graders(plan.graders)
  end

  def self.fingerprint_for_steps(grader_steps)
    payload = grader_steps.map do |step|
      details = step.details || {}
      {
        "name" => details["name"].to_s,
        "command" => details["command"].to_s,
        "required" => !!details["required"],
        "timeout_minutes" => details["timeout_minutes"].to_i,
        "when_files_changed" => Array(details["when_files_changed"]).map(&:to_s).sort
      }
    end

    digest(payload)
  end

  def self.successful?(repository:, commit_sha:, grader_fingerprint:)
    return false if repository.blank? || commit_sha.blank? || grader_fingerprint.blank?

    GraderConclusion.aggregate
                    .passed
                    .where(repository: repository, commit_sha: commit_sha, grader_fingerprint: grader_fingerprint)
                    .exists?
  end

  def self.latest_success(repository:, commit_sha:, grader_fingerprint:)
    return nil if repository.blank? || commit_sha.blank? || grader_fingerprint.blank?

    GraderConclusion.aggregate
                    .passed
                    .where(repository: repository, commit_sha: commit_sha, grader_fingerprint: grader_fingerprint)
                    .latest_first
                    .first
  end

  def self.record!(workflow:, run:, step:, commit_sha:, grader_steps:, aggregate_status:, grader_fingerprint: nil)
    return if commit_sha.blank? || grader_steps.empty?

    fingerprint = grader_fingerprint.presence || fingerprint_for_steps(grader_steps)
    checked_at = Time.current

    GraderConclusion.transaction do
      grader_steps.each do |grader_step|
        details = grader_step.details || {}
        GraderConclusion.create!(
          repository: workflow.job.repository,
          job: workflow.job,
          workflow: workflow,
          step: grader_step,
          run: grader_step.runs.order(:created_at).last,
          commit_sha: commit_sha,
          grader_fingerprint: fingerprint,
          grader_name: details["name"].presence || "grader-#{grader_step.id}",
          required: details.key?("required") ? !!details["required"] : nil,
          status: status_for_step(grader_step),
          exit_code: details["exit_code"],
          duration_s: details["duration_s"],
          timed_out: !!details["timed_out"],
          log_path: details["log_path"],
          log_bytes: details["log_bytes"],
          checked_at: checked_at,
          metadata: metadata_for(workflow: workflow, step: grader_step)
        )
      end

      GraderConclusion.create!(
        repository: workflow.job.repository,
        job: workflow.job,
        workflow: workflow,
        step: step,
        run: run,
        commit_sha: commit_sha,
        grader_fingerprint: fingerprint,
        grader_name: GraderConclusion::AGGREGATE_NAME,
        required: true,
        status: aggregate_status,
        timed_out: aggregate_status == "timed_out",
        checked_at: checked_at,
        metadata: {
          "trigger_kind" => workflow.trigger_kind,
          "iteration" => run.iteration,
          "loop_id" => step.loop_id,
          "grader_count" => grader_steps.size
        }.compact
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[GraderConclusionCache] record failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  def self.status_for_step(step)
    return "passed" if step.state == "succeeded"
    return "timed_out" if GraderFailureSignal.timeout_like_step?(step)
    return "cancelled" if step.state == "cancelled"
    return "failed" if step.state == "failed"

    "inconclusive"
  end

  def self.aggregate_status_for(failed_required)
    failed_required = Array(failed_required)
    return "passed" if failed_required.empty?
    return "timed_out" if failed_required.all? { |grader_step| GraderFailureSignal.timeout_like_step?(grader_step) }

    "failed"
  end

  def self.fingerprint_for_graders(graders)
    payload = Array(graders).map do |grader|
      {
        "name" => grader.name.to_s,
        "command" => grader.command.to_s,
        "required" => !!grader.required,
        "timeout_minutes" => grader.timeout_minutes.to_i,
        "when_files_changed" => Array(grader.when_files_changed).map(&:to_s).sort
      }
    end

    digest(payload)
  end

  def self.digest(payload)
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end
  private_class_method :digest

  def self.metadata_for(workflow:, step:)
    {
      "trigger_kind" => workflow.trigger_kind,
      "iteration" => step.iteration,
      "loop_id" => step.loop_id
    }.compact
  end
  private_class_method :metadata_for
end
