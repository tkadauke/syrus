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
        settings.with_lock do
          next unless settings.due?(now: now)

          successful_generations = 0
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
            successful_generations += 1
          rescue StandardError => e
            Rails.logger.warn("[OperatorBriefing::Scheduler] user=#{user.id} repository=#{subscription.repository_id} failed: #{e.class}: #{e.message}")
          end
          settings.record_scheduled!(at: now) if successful_generations.positive?
        end
      end
    end

    private

    attr_reader :now
  end
end
