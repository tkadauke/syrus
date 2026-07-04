module ReviewPolicies
  class Base
    def initialize(job)
      @job = job
    end

    def satisfied?
      raise NotImplementedError, "#{self.class} must implement #satisfied?"
    end

    def pending_description
      raise NotImplementedError, "#{self.class} must implement #pending_description"
    end

    private

    def effective_owner_id
      @effective_owner_id ||= @job.owner_user_id.presence || @job.user_id
    end

    def owner_approved?
      @job.job_approvals.where(user_id: effective_owner_id).exists?
    end
  end
end
