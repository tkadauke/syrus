class ExternalPrIngestRetryEnqueuer
  Result = Data.define(:workflow, :error) do
    def success? = workflow.present?
  end

  def self.call(...) = new(...).call

  def initialize(job:)
    @job = job
  end

  def call
    return failure("Only external PR Jobs can retry ingestion.") unless job.external_pr?

    workflow = nil
    failure_result = nil

    job.with_lock do
      job.reload
      if job.workflows.active.exists?
        failure_result = failure("A workflow is already running for this Job.")
      else
        state_error = prepare_job_state_for_retry
        if state_error
          failure_result = failure(state_error)
        else
          workflow = Workflows::ExternalPrIngest.instantiate(job: job)
        end
      end
    end

    return failure_result if failure_result

    StepDispatcher.start_workflow(workflow)
    Result.new(workflow: workflow, error: nil)
  end

  private

  attr_reader :job

  # A fresh external_pr_ingest attempt is a first-class retry, distinct
  # from the generic "retry failed step" path — it must not resume the
  # workflow that already failed. If the previous ingest drove the Job to
  # :failed (the same-repo path; see Workflows::ExternalPrIngest.after_fail),
  # move it back to :queued so Workflow#start's propagate_start_to_job!
  # can advance it once the new workflow actually begins running.
  def prepare_job_state_for_retry
    return nil unless job.failed?
    return "Job is not ready to retry yet." unless job.may_retry_after_failure?

    job.retry_after_failure!
    job.save!
    nil
  end

  def failure(message)
    Result.new(workflow: nil, error: message)
  end
end
