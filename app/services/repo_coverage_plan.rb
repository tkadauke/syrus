class RepoCoveragePlan
  Source = Data.define(:artifact, :format)
  Threshold = Data.define(:lines, :branches, :pr_lines)

  ON_MISS_VALUES = %w[block warn schedule].freeze
  SUPPORTED_FORMATS = -> { Coverage::ParserRegistry.formats }

  attr_reader :sources, :threshold, :on_miss, :pr_comment, :hitmap_ttl_days, :schedule_prompt

  def initialize(sources:, threshold:, on_miss:, pr_comment:, hitmap_ttl_days:, schedule_prompt:)
    @sources = sources
    @threshold = threshold
    @on_miss = on_miss
    @pr_comment = pr_comment
    @hitmap_ttl_days = hitmap_ttl_days
    @schedule_prompt = schedule_prompt
  end

  def threshold_miss?(lines_pct:, pr_delta_pct: nil)
    return false if threshold.nil?
    return true if threshold.lines && lines_pct && lines_pct < threshold.lines
    return true if threshold.pr_lines && pr_delta_pct && pr_delta_pct < threshold.pr_lines
    false
  end

  class << self
    def from_config(hash)
      raise SyrusYml::ConfigError, "coverage: must be a mapping" unless hash.is_a?(Hash)

      sources = hash.key?("sources") ? parse_sources(hash["sources"]) : parse_shorthand_source(hash)

      on_miss = hash.fetch("on_miss", "warn").to_s.strip
      unless ON_MISS_VALUES.include?(on_miss)
        raise SyrusYml::ConfigError,
          "coverage.on_miss: #{on_miss.inspect} is not valid; must be one of #{ON_MISS_VALUES.join(', ')}"
      end

      schedule_prompt = hash["schedule_prompt"]&.to_s&.strip&.presence
      if on_miss == "schedule" && schedule_prompt.nil?
        raise SyrusYml::ConfigError, "coverage.schedule_prompt: is required when on_miss is 'schedule'"
      end

      new(
        sources: sources,
        threshold: parse_threshold(hash["threshold"]),
        on_miss: on_miss,
        pr_comment: hash.key?("pr_comment") ? ActiveModel::Type::Boolean.new.cast(hash["pr_comment"]) : true,
        hitmap_ttl_days: parse_integer(hash.fetch("hitmap_ttl_days", 30), "coverage.hitmap_ttl_days"),
        schedule_prompt: schedule_prompt
      )
    end

    private

    def parse_shorthand_source(hash)
      artifact = hash["artifact"]&.to_s&.strip
      raise SyrusYml::ConfigError, "coverage.artifact: is required" if artifact.nil? || artifact.empty?

      format = hash.fetch("format", "lcov").to_s.strip
      validate_format!(format, "coverage.format")
      [ Source.new(artifact: artifact, format: format) ]
    end

    def parse_sources(raw)
      raise SyrusYml::ConfigError, "coverage.sources: must be an array" unless raw.is_a?(Array)
      raise SyrusYml::ConfigError, "coverage.sources: must not be empty" if raw.empty?

      raw.each_with_index.map do |src, index|
        raise SyrusYml::ConfigError, "coverage.sources[#{index}]: must be a mapping" unless src.is_a?(Hash)

        artifact = src["artifact"]&.to_s&.strip
        raise SyrusYml::ConfigError, "coverage.sources[#{index}].artifact: is required" if artifact.nil? || artifact.empty?

        format = src.fetch("format", "lcov").to_s.strip
        validate_format!(format, "coverage.sources[#{index}].format")

        Source.new(artifact: artifact, format: format)
      end
    end

    def validate_format!(format, context)
      supported = SUPPORTED_FORMATS.call rescue nil
      return unless supported
      unless supported.include?(format)
        raise SyrusYml::ConfigError,
          "#{context}: #{format.inspect} is not a supported format; must be one of #{supported.join(', ')}"
      end
    end

    def parse_threshold(raw)
      return nil if raw.nil?
      raise SyrusYml::ConfigError, "coverage.threshold: must be a mapping" unless raw.is_a?(Hash)

      Threshold.new(
        lines: parse_threshold_value(raw["lines"], "coverage.threshold.lines"),
        branches: parse_threshold_value(raw["branches"], "coverage.threshold.branches"),
        pr_lines: parse_threshold_value(raw["pr_lines"], "coverage.threshold.pr_lines")
      )
    end

    def parse_threshold_value(raw, context)
      return nil if raw.nil?
      Float(raw)
    rescue ArgumentError, TypeError
      raise SyrusYml::ConfigError, "#{context}: must be a number"
    end

    def parse_integer(raw, context)
      Integer(raw)
    rescue ArgumentError, TypeError
      raise SyrusYml::ConfigError, "#{context}: must be an integer"
    end
  end
end
