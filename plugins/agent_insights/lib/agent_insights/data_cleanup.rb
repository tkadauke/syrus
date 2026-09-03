module AgentInsights
  # What used to be `Repository has_many :insight_suggestions` and
  # `has_one :insight_schedule_config`, both `dependent: :destroy`, injected
  # onto the core model at boot.
  #
  # Registered without a `plugin:` scope: disabling this plugin stops insight
  # sweeps running, it does not delete the suggestions already filed, and those
  # still have to go when their repository does.
  module DataCleanup
    def self.install!
      Syrus::Installer.define("agent_insights:data_cleanup") do |scope|
        scope.effect("repository suggestions") do
          Syrus::DataCleanup.register("Repository", "agent_insights.suggestions") do |repository|
            AgentInsights::Suggestion.for_repository(repository).find_each(&:destroy)
          end
        end

        scope.effect("repository schedule config") do
          Syrus::DataCleanup.register("Repository", "agent_insights.schedule_config") do |repository|
            AgentInsights::ScheduleConfig.for_repository(repository)&.destroy
          end
        end
      end
    end
  end
end
