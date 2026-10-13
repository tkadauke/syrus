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

        accessible_repository_ids = Repository.accessible_repository_ids_for(user)
        settings.enabled_subscriptions.where.not(repository_id: accessible_repository_ids).find_each do |subscription|
          subscription.update!(enabled: false)
        end

        settings.enabled_subscriptions
          .where(repository_id: accessible_repository_ids)
          .includes(:repository)
          .find_each do |subscription|
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
