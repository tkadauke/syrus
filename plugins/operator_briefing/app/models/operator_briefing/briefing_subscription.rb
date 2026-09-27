module OperatorBriefing
  class BriefingSubscription < ApplicationRecord
    self.table_name = "operator_briefing_subscriptions"

    belongs_to :user
    belongs_to :repository

    validates :user_id, uniqueness: { scope: :repository_id }

    scope :enabled, -> { where(enabled: true) }

    def self.seed_for_user!(user)
      Repository.where(id: Repository.accessible_repository_ids_for(user)).find_each do |repository|
        find_or_create_by!(user: user, repository: repository) do |subscription|
          subscription.enabled = true
        end
      end
    end
  end
end
