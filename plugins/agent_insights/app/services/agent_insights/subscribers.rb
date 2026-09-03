module AgentInsights
  # Triggers an insight sweep when a repository has closed enough coding work
  # to be worth surveying again.
  #
  # This was Job#after_update_commit :trigger_insight_if_max_threshold_reached
  # -- an Active Record callback in core, calling a service in core, for a
  # feature that is not core's. It is a job.closed subscriber now.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      { "job.closed" => :on_job_closed }
    end

    def self.on_job_closed(event)
      # An insight sweep closing its own Job must not count as coding work and
      # schedule the next sweep, or sweeps would chain forever.
      return if event[:kind].to_s == "agent_insight"

      repository = Repository.find_by(id: event[:repository_id])
      return if repository.nil?

      config = repository.insight_schedule_config
      return unless config&.enabled?

      last_insight_at = Scheduler.last_insight_created_at(repository)
      return if Scheduler.coding_jobs_since(repository, last_insight_at) < config.max_jobs_since_last_run

      Scheduler.enqueue_if_idle!(repository)
    rescue StandardError => e
      Rails.logger.error("[AgentInsights] insight scheduling failed for repository #{event[:repository_id]}: #{e.class}: #{e.message}")
    end
  end
end
