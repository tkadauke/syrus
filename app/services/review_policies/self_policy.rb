module ReviewPolicies
  class SelfPolicy < Base
    def satisfied?
      owner_approved?
    end
  end
end
