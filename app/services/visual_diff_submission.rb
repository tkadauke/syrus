class VisualDiffSubmission
  Result = Data.define(:workflow, :run, :error) do
    def success? = error.blank?
  end

  AUTOMATIC_SOURCE = "visual_review".freeze
  MANUAL_SOURCE = "manual".freeze
  BASELINE_TYPE = "visual_diff_baseline_screenshot".freeze

  def self.call(job:, source: MANUAL_SOURCE, after_workflow: nil, after_iteration: nil)
    new(job: job, source: source, after_workflow: after_workflow, after_iteration: after_iteration).call
  end

  def self.enqueue_deferred_for_visual_review(workflow)
    iteration = latest_approved_iteration_with_artifacts(workflow)
    return unless iteration

    call(
      job: workflow.job,
      source: AUTOMATIC_SOURCE,
      after_workflow: workflow,
      after_iteration: iteration["iteration"]
    )
  rescue StandardError => e
    Rails.logger.warn("[VisualDiffSubmission] deferred enqueue failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  def self.enqueue_deferred_for_job(job)
    job.workflows
      .where(trigger_kind: %w[initial retry pr_comment chat_feedback manual_visual_review])
      .order(created_at: :desc, id: :desc)
      .each do |workflow|
        result = enqueue_deferred_for_visual_review(workflow)
        return result if result&.success?
      end
  end

  def self.latest_approved_iteration_with_artifacts(workflow)
    Array(workflow.artifact("visual_review_iterations")).reverse.find do |iteration|
      iteration.is_a?(Hash) &&
        iteration["verdict"] == "approved" &&
        Array(iteration["artifacts"]).any?
    end
  end

  attr_reader :job, :source, :after_workflow, :after_iteration

  def initialize(job:, source:, after_workflow:, after_iteration:)
    @job = job
    @source = source.to_s
    @after_workflow = after_workflow
    @after_iteration = after_iteration
  end

  def call
    return failure("Before/after comparison can only be run on implemented, approved, or landing Jobs with no active run.") unless runnable?
    return failure("Visual review is not configured for this repository.") unless RepoVisualReviewPlan.for_job(job).enabled?
    return failure("No visual review screenshots are available to compare.") if after_artifacts.empty?

    result = WorkUnits::Launcher.create_and_start!(
      kind: "visual_diff",
      job: job,
      artifacts: launch_artifacts,
      idempotency_key: idempotency_key,
      source_type: "visual_diff",
      source_id: after_workflow&.id,
      before_start: ->(workflow) { workflow.update!(priority: "low") }
    )
    Result.new(workflow: result.workflow, run: result.run, error: nil)
  end

  private

  def failure(message)
    Result.new(workflow: nil, run: nil, error: message)
  end

  def runnable?
    job.visual_diff_runnable?
  end

  def idempotency_key
    return nil if source == MANUAL_SOURCE

    "visual-diff:#{job.id}:#{after_workflow&.id}:#{after_iteration}"
  end

  def launch_artifacts
    {
      "visual_diff_source" => source,
      "visual_diff_after_workflow_id" => after_workflow&.id,
      "visual_diff_after_iteration" => after_iteration,
      "visual_diff_after_artifacts" => after_artifacts,
      "visual_diff_baseline_type" => BASELINE_TYPE
    }
  end

  def after_artifacts
    @after_artifacts ||= begin
      if after_workflow
        artifacts_for_workflow(after_workflow, after_iteration)
      else
        latest_visual_artifacts
      end
    end
  end

  def latest_visual_artifacts
    job.workflows
      .where(trigger_kind: %w[initial retry pr_comment chat_feedback manual_visual_review])
      .order(created_at: :desc, id: :desc)
      .lazy
      .map { |workflow| artifacts_for_workflow(workflow, nil) }
      .find(&:present?) || []
  end

  def artifacts_for_workflow(workflow, iteration_number)
    iterations = Array(workflow.artifact("visual_review_iterations"))
    iterations = iterations.select { |entry| entry["iteration"].to_i == iteration_number.to_i } if iteration_number.present?
    iterations.reverse_each.flat_map { |entry| Array(entry["artifacts"]) }.select { |entry| entry.is_a?(Hash) && entry["image_url"].present? }
  end
end
