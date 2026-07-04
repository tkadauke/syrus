module ReviewPolicies
  class FinalSayPolicy < Base
    def satisfied?
      final_approver_ids = @job.repository.final_approver_ids
      if final_approver_ids.include?(@job.owner_user_id)
        owner_approved?
      else
        owner_approved? &&
          @job.job_approvals.where(user_id: final_approver_ids).exists?
      end
    end
  end
end
