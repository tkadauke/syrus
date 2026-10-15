module AlertmanagerInvestigations
  class Configuration
    DEFAULT_RATE_LIMIT_MINUTES = 30
    DEFAULT_HOST_LABEL = "instance".freeze
    DEFAULT_MAX_JOBS_PER_TICK = 5
    DEFAULT_MAX_OPEN_JOBS_PER_REPOSITORY = 10

    def self.current = new

    def initialize(record: PluginRecord.find_by(name: "alertmanager_investigations"))
      @settings = record&.config.to_h.dig("settings").to_h
    end

    def base_url
      ENV["ALERTMANAGER_URL"].presence || @settings["base_url"].to_s.strip.presence
    end

    def bearer_token
      ENV["ALERTMANAGER_BEARER_TOKEN"].to_s.presence
    end

    def rate_limit_window
      minutes = @settings["rate_limit_minutes"].to_i
      minutes = DEFAULT_RATE_LIMIT_MINUTES if minutes <= 0
      minutes.minutes
    end

    def host_label
      @settings["host_label"].to_s.strip.presence || DEFAULT_HOST_LABEL
    end

    def max_jobs_per_tick
      positive_integer("max_jobs_per_tick", DEFAULT_MAX_JOBS_PER_TICK)
    end

    def max_open_jobs_per_repository
      positive_integer("max_open_jobs_per_repository", DEFAULT_MAX_OPEN_JOBS_PER_REPOSITORY)
    end

    private

    def positive_integer(key, default)
      value = @settings[key].to_i
      value.positive? ? value : default
    end
  end
end
