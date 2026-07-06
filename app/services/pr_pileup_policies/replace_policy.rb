module PrPileupPolicies
  class ReplacePolicy < Base
    def check_pileup
      fire_service.close_prior_open_prs
      nil
    end
  end
end
