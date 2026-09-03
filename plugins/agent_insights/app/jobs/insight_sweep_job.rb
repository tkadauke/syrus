class InsightSweepJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform
    return unless AgentInsights.enabled?

    AgentInsights::ScheduleConfig.where(enabled: true).includes(:repository).find_each do |config|
      repository = config.repository
      next if repository.archived?

      last_insight_at = AgentInsights::Scheduler.last_insight_created_at(repository)
      count = AgentInsights::Scheduler.coding_jobs_since(repository, last_insight_at)
      next if count < config.min_jobs_since_last_run

      AgentInsights::Scheduler.enqueue_if_idle!(repository)
    rescue StandardError => e
      Rails.logger.warn("[InsightSweepJob] repository #{config.repository_id} failed: #{e.class}: #{e.message}")
    end
  end
end
