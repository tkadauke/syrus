module ReviewPolicies
  class TwoPersonPolicy < Base
    def multi_person?
      true
    end

    def satisfied?
      owner_approved? &&
        approval_from_non_owner?
    end

    def pending_description
      return "Waiting for owner approval" unless owner_approved?

      "Waiting for one additional approval" unless approval_from_non_owner?
    end
  end
end
