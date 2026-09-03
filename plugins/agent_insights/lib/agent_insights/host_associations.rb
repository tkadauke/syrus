module AgentInsights
  # Core does not own insight suggestions, so Repository does not declare these.
  module HostAssociations
    def self.apply!
      return if Repository.reflect_on_association(:insight_suggestions)

      Repository.has_many :insight_suggestions,
                          class_name: "AgentInsights::Suggestion",
                          foreign_key: :repository_id,
                          inverse_of: :repository,
                          dependent: :destroy
      Repository.has_one :insight_schedule_config,
                         class_name: "AgentInsights::ScheduleConfig",
                         foreign_key: :repository_id,
                         inverse_of: :repository,
                         dependent: :destroy
    end
  end
end
