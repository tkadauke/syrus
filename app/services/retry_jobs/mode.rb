module RetryJobs
  class Mode
    MODES = {
      "auto" => "RetryJobs::Modes::Auto",
      "failed_step" => "RetryJobs::Modes::FailedStep",
      "implementation" => "RetryJobs::Modes::Implementation",
      "refresh_base" => "RetryJobs::Modes::RefreshBase"
    }.freeze

    Result = Data.define(:eligible, :message, :details) do
      def eligible? = eligible
    end

    def self.for(name)
      MODES.fetch(name.to_s).constantize
    rescue KeyError
      raise ArgumentError, "mode must be one of: #{MODES.keys.join(', ')}"
    end

    def initialize(job:, source_workflow_id: nil, reason: nil)
      @job = job
      @source_workflow_id = source_workflow_id
      @reason = reason.to_s.strip
    end

    def preflight
      raise NotImplementedError
    end

    def execute
      raise NotImplementedError
    end

    def group_confirmation_strategy = "independent"

    protected

    attr_reader :job, :source_workflow_id, :reason

    # `retiring_workflow` is a Workflow the retry itself will retire before it
    # starts, so its own WorkUnit and Runs are not "other" active work.
    def retry_preflight(extra = {}, retiring_workflow: nil)
      active = if retiring_workflow
        WorkUnits::Ownership.active_units_for_job(job).any? { |unit| unit.workflow_id != retiring_workflow.id }
      else
        WorkUnits::Ownership.active_for_job?(job)
      end
      return failure("Active mutation work must finish before retrying this Job.") if active

      eligibility = RetryWorkflowEligibility.call(job: job, workflow: retiring_workflow)
      return failure(eligibility.message) unless eligibility.eligible?

      success(extra)
    end

    def source_workflow
      scope = job.workflows.where(state: "failed")
      source_workflow_id.present? ? scope.find_by(id: source_workflow_id) : scope.order(created_at: :desc, id: :desc).first
    end

    def success(details = {}) = Result.new(eligible: true, message: nil, details: details)
    def failure(message, details = {}) = Result.new(eligible: false, message: message, details: details)
  end
end
