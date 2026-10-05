module DiffReviewVersions
  class FinalReviewVersion
    def self.resolve(job:, workflow: nil, run: nil)
      new(job: job, workflow: workflow, run: run).resolve
    end

    def initialize(job:, workflow:, run:)
      @job = job
      @workflow = workflow
      @run = run
    end

    def resolve
      return nil unless job
      return nil if mismatched_job_context?

      exact_match || DiffReviewVersion.default_for_review(job)
    end

    private

    attr_reader :job, :workflow, :run

    def mismatched_job_context?
      (workflow && workflow.job_id != job.id) ||
        (run && run.job_id != job.id)
    end

    def exact_match
      DiffReviewVersion.best_match_for(
        job_id: job.id,
        run_id: run&.id,
        workflow_id: workflow&.id
      )
    end
  end
end
