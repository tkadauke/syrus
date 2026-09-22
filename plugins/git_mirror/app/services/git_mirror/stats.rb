module GitMirror
  # The mirror's view of itself -- repositories, sizes, disk -- for the
  # plugin's gauges and the Plugin Services details panel. Cached briefly so
  # the four gauges sampled on one tick share a single request.
  module Stats
    CACHE_KEY = "syrus:git_mirror:stats".freeze
    CACHE_TTL = 30.seconds

    module_function

    # nil when the service is not available or cannot be reached.
    def current(endpoint: ContentProvider.endpoint)
      return nil unless endpoint

      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { Client.new(endpoint: endpoint).stats }
    rescue RepositoryContent::Error => e
      Rails.logger.warn("[GitMirror] stats unavailable: #{e.message}")
      nil
    end

    def disk(key)
      current&.dig("disk", key)
    end

    def repository_count
      current&.fetch("repositories", nil)&.size
    end
  end
end
