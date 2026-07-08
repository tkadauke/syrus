class ResumeWorkflowEnqueuer
  Result = Data.define(:run, :workflow, :step, :error) do
    def success? = run.present?
  end

  def self.call(...) = new(...).call

  def initialize(job:, source_run:)
    @job = job
    @source_run = source_run
  end

  def call
    return failure("Source Run not found.") unless source_run
    return failure("Source Run does not belong to this Job.") unless source_run.job_id == job.id
    return failure("Only failed or cancelled Runs are resumable.") unless source_run.failed? || source_run.cancelled?
    return failure("A Run is already in progress - wait for it to finish.") if job.any_active_run?

    session = source_run.claude_session
    return failure("No agent session captured for that Run - try Retry instead.") unless session

    failed_workflow = source_run.step&.workflow
    return failure("Could not find the workflow for this Run.") unless failed_workflow

    retry_result = RetryFailedStepEnqueuer.call(
      workflow: failed_workflow,
      parent_session_id: session.session_id,
      prompt: Prompts::Resume.new.to_s
    )

    return failure(retry_result.error) unless retry_result.success?

    Result.new(run: retry_result.run, workflow: retry_result.workflow, step: retry_result.step, error: nil)
  end

  private

  attr_reader :job, :source_run

  def failure(message)
    Result.new(run: nil, workflow: nil, step: nil, error: message)
  end
end
