module PrPileupPolicies
  class SkipPolicy < Base
    def check_pileup
      return unless task.has_open_pr?

      task.record_fire!(at: fire_service.now)
      ScheduledTaskFire::Result.new(job: nil, skipped: true, reason: "prior_pr_open")
    end
  end
end
