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

    module_function

    # The plugin that owns an origin key, or nil when nothing claims it --
    # which is the normal state for a disabled or uninstalled plugin, not an
    # error.
    def provider_for(origin)
      return nil if origin.blank? || origin == CORE

      Syrus::PluginRegistry.providers_for(:job_origin).find do |provider|
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
