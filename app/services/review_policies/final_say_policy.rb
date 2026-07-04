module ReviewPolicies
  class FinalSayPolicy < Base
    def satisfied?
      if owner_is_final_approver?
        owner_approved?
      else
        owner_approved? &&
          @job.job_approvals.where(user_id: final_approver_ids).exists?
      end
    end

    def pending_description
      if owner_is_final_approver?
        owner_approved? ? nil : "Waiting for owner to approve"
      elsif !owner_approved?
        "Waiting for owner approval"
      elsif !@job.job_approvals.where(user_id: final_approver_ids).exists?
        "Waiting for final approver"
      end
    end

    private

    def final_approver_ids
      @final_approver_ids ||= @job.repository.final_approver_ids
    end

    def owner_is_final_approver?
      @job.owner_user_id && final_approver_ids.include?(@job.owner_user_id)
    end
  end
end
