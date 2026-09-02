module ReviewPolicies
  class Base
    def initialize(job, approvals: nil)
      @job = job
      @preloaded_approvals = approvals
    end

    def satisfied?
      raise NotImplementedError, "#{self.class} must implement #satisfied?"
    end

    def pending_description
      raise NotImplementedError, "#{self.class} must implement #pending_description"
    end

    def multi_person?
      false
    end

    private

    def effective_owner_id
      @effective_owner_id ||= @job.owner_user_id.presence || @job.user_id
    end

    def owner_approved?
      approval_from?(effective_owner_id)
    end

    def approval_from?(user_ids)
      ids = Array(user_ids).compact
      return false if ids.empty?

      if @preloaded_approvals
        @preloaded_approvals.any? { |approval| ids.include?(approval.user_id) }
      else
        @job.job_approvals.where(user_id: ids).exists?
      end
    end

    def approval_from_non_owner?
      if @preloaded_approvals
        @preloaded_approvals.any? { |approval| approval.user_id != effective_owner_id }
      else
        @job.job_approvals.where.not(user_id: effective_owner_id).exists?
      end
    end
  end
end
