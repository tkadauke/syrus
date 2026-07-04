module ReviewPolicies
  class Base
    def initialize(job)
      @job = job
    end

    def satisfied?
      raise NotImplementedError, "#{self.class} must implement #satisfied?"
    end

    private

    def owner_approved?
      @job.job_approvals.where(user_id: @job.owner_user_id).exists?
    end
  end
end
