module ReviewPolicies
  class TwoPersonPolicy < Base
    def satisfied?
      owner_approved? &&
        @job.job_approvals.where.not(user_id: @job.owner_user_id).exists?
    end

    def pending_description
      return "Waiting for owner approval" unless owner_approved?
      return "Waiting for one additional approval" unless @job.job_approvals.where.not(user_id: @job.owner_user_id).exists?
    end
  end
end
