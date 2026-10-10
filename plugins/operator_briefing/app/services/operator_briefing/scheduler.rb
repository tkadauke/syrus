module OperatorBriefing
  class Scheduler
    def self.run!(now: Time.current)
      new(now: now).run!
    end

    def initialize(now:)
      @now = now
    end

    def run!
      User.where(id: BriefingSubscription.enabled.select(:user_id)).find_each do |user|
        settings = BriefingSettings.for_user(user)
        next unless settings.due?(now: now)

        settings.enabled_subscriptions.includes(:repository).find_each do |subscription|
          repository = subscription.repository
          next if repository.archived?

          Generator.generate!(user: user, repository: repository, mode: :scheduled, now: now)
        rescue StandardError => e
          Rails.logger.warn("[OperatorBriefing::Scheduler] user=#{user.id} repository=#{subscription.repository_id} failed: #{e.class}: #{e.message}")
        end
        settings.record_scheduled!(at: now)
      end
    end

    private

    attr_reader :now
  end
end
