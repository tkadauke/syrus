class Job
  # Where a Job came from, resolved through the plugin that created it.
  #
  # `jobs.origin` is a plugin name (or "core"); `jobs.origin_id` is that
  # plugin's opaque identifier for the thing that caused the Job -- an issue
  # number, a ScheduledTask id, an InsightSuggestion id. Several Jobs may share
  # one origin_id: a recurring schedule fires repeatedly, and that is correct.
  #
  # No URL is ever stored. URLs change when a repository is renamed or an
  # instance is rehosted, so the owning plugin computes one on demand.
  module Origin
    CORE = "core".freeze

    # Core seeds its own origins through the same lookup plugins use, so
    # "core" is not a special case in the rendering path and moving one of
    # these into a plugin changes no caller.
    BUILT_IN_PROVIDERS = [ "JobOrigins::ScheduledTasks" ].freeze

    module_function

    # The plugin that owns an origin key, or nil when nothing claims it --
    # which is the normal state for a disabled or uninstalled plugin, not an
    # error.
    def provider_for(origin)
      return nil if origin.blank? || origin == CORE

      candidates = BUILT_IN_PROVIDERS.filter_map { |name| name.safe_constantize } +
                   Syrus::PluginRegistry.providers_for(:job_origin)

      candidates.find do |provider|
        provider.respond_to?(:origin_key) && provider.origin_key.to_s == origin.to_s
      end
    end

    # Human-readable name for the originating thing. Falls back to the raw
    # identifier so a disabled plugin degrades to plain text rather than a
    # blank or a crash.
    def label(job)
      return nil if job.nil? || job.origin_id.blank?

      provider = provider_for(job.origin)
      return job.origin_id.to_s unless provider

      provider.label(origin_id: job.origin_id, repository: job.repository).presence || job.origin_id.to_s
    rescue StandardError => e
      Rails.logger.warn("[Job::Origin] label failed for #{job.origin}/#{job.origin_id}: #{e.class}: #{e.message}")
      job.origin_id.to_s
    end

    # The title/body an origin supplies for a Job with no issue behind it.
    # Returns nil when nothing claims the origin or it has no prompt, which is
    # what lets Job#synthetic_issue stop naming ScheduledTask.
    def synthetic_issue(job)
      return nil if job.nil? || job.origin_id.blank?

      provider = provider_for(job.origin)
      return nil unless provider

      supplied = provider.synthetic_issue(origin_id: job.origin_id, repository: job.repository)
      return nil unless supplied.is_a?(Hash)

      supplied
    rescue StandardError => e
      Rails.logger.warn("[Job::Origin] synthetic_issue failed for #{job.origin}/#{job.origin_id}: #{e.class}: #{e.message}")
      nil
    end

    # The auto-approval mode this Job's origin asks for, or nil.
    def auto_approve_mode(job)
      return nil if job.nil? || job.origin_id.blank?

      provider = provider_for(job.origin)
      return nil unless provider

      provider.auto_approve_mode(origin_id: job.origin_id, repository: job.repository)
    rescue StandardError => e
      Rails.logger.warn("[Job::Origin] auto_approve_mode failed for #{job.origin}/#{job.origin_id}: #{e.class}: #{e.message}")
      nil
    end

    # A link to the originating thing, or nil when there is nothing to link to.
    def url(job)
      return nil if job.nil? || job.origin_id.blank?

      provider = provider_for(job.origin)
      return nil unless provider

      provider.url(origin_id: job.origin_id, repository: job.repository)
    rescue StandardError => e
      Rails.logger.warn("[Job::Origin] url failed for #{job.origin}/#{job.origin_id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
