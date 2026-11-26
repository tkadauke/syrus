module SyrusCoverage
  # Owns the `.syrus.yml` coverage schema. The top-level `coverage:` key is the
  # plugin's compatibility alias for the namespaced
  # `plugins: { syrus_coverage.config: ... }` envelope, so existing repositories
  # keep working unchanged and a repository can use either spelling.
  #
  # The parsed value is a SyrusCoverage::Plan (the repository-wide plan; the
  # per-project copy is made by Plan#with_project).
  class RepositoryConfiguration
    include Syrus::Host::RepositoryConfiguration

    KEY = "syrus_coverage.config".freeze

    def self.schema_version = 1

    def self.parse(value:, version:, scope:)
      raise ArgumentError, "unsupported schema version #{version}" unless version == schema_version

      parse_plan(value)
    end

    def self.serialize(value:)
      return nil if value.nil?

      {
        "sources" => value.sources.map { |source| { "artifact" => source.artifact, "format" => source.format } },
        "threshold" => value.threshold && value.threshold.to_h.transform_keys(&:to_s),
        "on_miss" => value.on_miss,
        "hitmap_ttl_days" => value.hitmap_ttl_days,
        "pr_comment" => value.pr_comment,
        "schedule_prompt" => value.schedule_prompt
      }
    end

    # A nested project's own block replaces the root's rather than merging with
    # it: sources are paths relative to the block's own directory, so a merged
    # list would be meaningless.
    def self.overlay(root:, project:)
      project.nil? ? root : project
    end

    def self.parse_plan(raw)
      return nil if raw.nil?
      raise Syrus::Host::SyrusYmlParseError, "coverage: must be a mapping" unless raw.is_a?(Hash)

      on_miss = (raw["on_miss"] || SyrusCoverage::Plan::DEFAULT_ON_MISS).to_s.strip
      unless SyrusCoverage::Plan::VALID_ON_MISS.include?(on_miss)
        raise Syrus::Host::SyrusYmlParseError, "coverage.on_miss: must be one of #{SyrusCoverage::Plan::VALID_ON_MISS.join(', ')}"
      end

      hitmap_ttl_days = raw.key?("hitmap_ttl_days") ? Integer(raw["hitmap_ttl_days"]) : SyrusCoverage::Plan::DEFAULT_HITMAP_TTL_DAYS
      raise Syrus::Host::SyrusYmlParseError, "coverage.hitmap_ttl_days: must be positive" unless hitmap_ttl_days > 0

      SyrusCoverage::Plan.new(
        sources: parse_sources(raw["sources"]),
        threshold: SyrusCoverage::Plan.parse_threshold(raw["threshold"], label_prefix: "coverage.threshold"),
        on_miss: on_miss,
        hitmap_ttl_days: hitmap_ttl_days,
        pr_comment: ActiveModel::Type::Boolean.new.cast(raw["pr_comment"]) || false,
        schedule_prompt: raw["schedule_prompt"].to_s.strip.presence
      )
    rescue ArgumentError, TypeError
      raise Syrus::Host::SyrusYmlParseError, "coverage.hitmap_ttl_days: must be an integer"
    end

    def self.parse_sources(raw)
      raise Syrus::Host::SyrusYmlParseError, "coverage.sources: must be an array" unless raw.is_a?(Array)
      raise Syrus::Host::SyrusYmlParseError, "coverage.sources: must not be empty" if raw.empty?

      raw.each_with_index.map do |item, index|
        label = "coverage.sources[#{index}]"
        raise Syrus::Host::SyrusYmlParseError, "#{label}: must be a mapping" unless item.is_a?(Hash)

        artifact = item["artifact"].to_s.strip
        raise Syrus::Host::SyrusYmlParseError, "#{label}.artifact: is required" if artifact.empty?

        format = item["format"].to_s.strip.downcase
        unless SyrusCoverage::Plan::VALID_FORMATS.include?(format)
          raise Syrus::Host::SyrusYmlParseError, "#{label}.format: must be one of #{SyrusCoverage::Plan::VALID_FORMATS.join(', ')}"
        end

        SyrusCoverage::Plan::Source.new(artifact: artifact, format: format)
      end
    end
    private_class_method :parse_plan, :parse_sources
  end
end
