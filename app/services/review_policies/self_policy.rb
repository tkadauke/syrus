module ReviewPolicies
  class SelfPolicy < Base
    def satisfied?
      owner_approved?
    end

    def pending_description
      satisfied? ? nil : "Waiting for owner to approve"
    end
  end
end
