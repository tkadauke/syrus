module ScheduledTasks
  # Suggests setting up a maintenance schedule on a repository that has signals
  # for it but no schedules yet.
  #
  # This was App::RepositoryFeatureRecommendations#scheduled_coverage, a core
  # method reaching into this plugin's models through
  # `repository.scheduled_tasks` and `user.cron_templates`.
  class Recommendations
    include Syrus::Plugin::RepositoryRecommendation

    ACTIVE_STATES = %w[scheduled paused auto_paused].freeze
    COVERAGE_TEMPLATE = "Increase test coverage".freeze

    def self.repository_recommendations(repository:, user: nil)
      return [] if repository.blank?
      return [] if scheduled_already?(repository)

      template = user && ScheduledTasks::CronTemplate.find_by(user_id: user.id, name: COVERAGE_TEMPLATE)
      path = "/repositories/#{repository.id}/scheduled_tasks/new"
      path += "?from_template=#{template.id}" if template

      [
        {
          id: "scheduled_coverage",
          title: "Schedule coverage upkeep",
          body: "Run periodic maintenance before test debt turns into review friction.",
          tone: "gray",
          category: "maintenance",
          order: 90,
          cta: { label: "Create schedule", kind: "link", path: path, method: "GET" },
          secondary_path: "/repositories/#{repository.id}/scheduled_tasks"
        }
      ]
    end

    def self.scheduled_already?(repository)
      ScheduledTasks::Task.where(repository_id: repository.id).alive.where(state: ACTIVE_STATES).exists?
    end
    private_class_method :scheduled_already?
  end
end
