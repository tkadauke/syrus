module ReviewPolicies
  class TwoPersonPolicy < Base
    def multi_person?
      true
    end

    def satisfied?
      owner_approved? &&
        @job.job_approvals.where.not(user_id: effective_owner_id).exists?
    end

    def pending_description
      return "Waiting for owner approval" unless owner_approved?

      "Waiting for one additional approval" unless @job.job_approvals.where.not(user_id: effective_owner_id).exists?
    end
  end
end
