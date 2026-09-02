module ReviewPolicies
  class FinalSayPolicy < Base
    def multi_person?
      true
    end

    def satisfied?
      if owner_is_final_approver?
        owner_approved?
      else
        owner_approved? &&
          approval_from?(final_approver_ids)
      end
    end

    def pending_description
      if owner_is_final_approver?
        owner_approved? ? nil : "Waiting for owner to approve"
      elsif !owner_approved?
        "Waiting for owner approval"
      elsif !approval_from?(final_approver_ids)
        "Waiting for final approver"
      end
    end

    private

    def final_approver_ids
      @final_approver_ids ||= @job.repository.final_approver_ids
    end

    def owner_is_final_approver?
      final_approver_ids.include?(effective_owner_id)
    end
  end
end
