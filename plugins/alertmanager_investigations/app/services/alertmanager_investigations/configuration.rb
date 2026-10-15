module AlertmanagerInvestigations
  class Configuration
    DEFAULT_RATE_LIMIT_MINUTES = 30
    DEFAULT_HOST_LABEL = "instance".freeze

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

    def runbook_allowed?(repository, path)
      allowed_runbooks.any? { |entry| entry.allows?(repository, path) }
    end

    private

    AllowlistEntry = Data.define(:repository_slug, :path_prefix) do
      def allows?(repository, path)
        repository.slug.casecmp?(repository_slug) &&
          (path == path_prefix || path.start_with?("#{path_prefix}/"))
      end
    end

    def allowed_runbooks
      @settings["allowed_runbooks"].to_s.lines.filter_map do |line|
        repository_slug, path_prefix = line.strip.split(":", 2)
        path_prefix = path_prefix.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        next unless repository_slug.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z}) && path_prefix.present?

        AllowlistEntry.new(repository_slug: repository_slug, path_prefix: path_prefix)
      end
    end
  end
end
