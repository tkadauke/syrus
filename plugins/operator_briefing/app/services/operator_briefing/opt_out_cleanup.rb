module OperatorBriefing
  class OptOutCleanup
    def self.cancel_for_subscription!(subscription)
      new(user_id: subscription.user_id, repository_id: subscription.repository_id).cancel!
    end

    def self.cancel_for_subscription_ids!(subscription_ids)
      BriefingSubscription.where(id: subscription_ids).find_each do |subscription|
        cancel_for_subscription!(subscription)
      end
    end

    def initialize(user_id:, repository_id:)
      @user_id = user_id
      @repository_id = repository_id
    end

    def cancel!
      active_briefings.find_each do |briefing|
        briefing.job.cancel_active_runs_and_close!("cancelled")
      end
    end

    private

    attr_reader :user_id, :repository_id

    def active_briefings
      Briefing
        .joins(:job)
        .where(owner_user_id: user_id, repository_id: repository_id, jobs: { kind: "briefing_generate" })
        .where.not(jobs: { state: Job::TERMINAL_STATES })
        .includes(:job)
    end
  end
end
