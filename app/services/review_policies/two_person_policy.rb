module ReviewPolicies
  class TwoPersonPolicy < Base
    def satisfied?
      owner_approved? &&
        @job.job_approvals.where.not(user_id: effective_owner_id).exists?
    end

    def pending_description
      return "Waiting for owner approval" unless owner_approved?
      return "Waiting for one additional approval" unless @job.job_approvals.where.not(user_id: effective_owner_id).exists?
    end
  end
end
