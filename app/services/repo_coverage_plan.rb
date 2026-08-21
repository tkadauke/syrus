class RepoCoveragePlan
  Source    = Data.define(:artifact, :format)
  Threshold = Data.define(:lines, :branches, :pr_lines)

  VALID_ON_MISS        = %w[block warn schedule].freeze
  VALID_FORMATS        = %w[lcov cobertura].freeze
  DEFAULT_ON_MISS      = "warn".freeze
  DEFAULT_HITMAP_TTL_DAYS = 30

  attr_reader :sources, :threshold, :on_miss, :hitmap_ttl_days, :pr_comment, :schedule_prompt

  def self.for(workspace_path)
    path = Pathname.new(workspace_path)
    return nil unless path.join(SyrusYml::CONFIG_FILE).exist?

    SyrusYml.load_repo(path).coverage
  rescue SyrusYml::ParseError => e
    Rails.logger.warn("[RepoCoveragePlan] .syrus.yml parse error: #{e.message}")
    nil
  end

  # Factory for direct hash parsing (from_config is used by RepoCoveragePlanReader via SyrusYml
  # when reading the YAML from GitHub at workflow-instantiation time).
  def self.from_config(raw)
    raise SyrusYml::ConfigError, "coverage: must be a mapping" unless raw.is_a?(Hash)

    sources = if raw.key?("sources")
      parse_sources_from_config(raw["sources"])
    elsif raw.key?("artifact")
      artifact = raw["artifact"].to_s.strip
      raise SyrusYml::ConfigError, "artifact: is required" if artifact.empty?
      format = (raw["format"] || "lcov").to_s.strip.downcase
      unless VALID_FORMATS.include?(format)
        raise SyrusYml::ConfigError, "format: must be one of #{VALID_FORMATS.join(', ')}"
      end
      [ Source.new(artifact: artifact, format: format) ]
    else
      raise SyrusYml::ConfigError, "artifact: is required"
    end

    threshold = parse_threshold(raw["threshold"], label_prefix: "threshold")

    on_miss = (raw["on_miss"] || DEFAULT_ON_MISS).to_s.strip
    unless VALID_ON_MISS.include?(on_miss)
      raise SyrusYml::ConfigError, "on_miss: #{on_miss.inspect} is not valid; must be one of #{VALID_ON_MISS.join(', ')}"
    end

    schedule_prompt = raw.key?("schedule_prompt") ? raw["schedule_prompt"].to_s.strip.presence : nil
    if on_miss == "schedule" && schedule_prompt.nil?
      raise SyrusYml::ConfigError, "schedule_prompt: is required when on_miss is 'schedule'"
    end

    hitmap_ttl_days = raw.key?("hitmap_ttl_days") ? raw["hitmap_ttl_days"] : DEFAULT_HITMAP_TTL_DAYS
    unless hitmap_ttl_days.is_a?(Integer)
      raise SyrusYml::ConfigError, "hitmap_ttl_days: must be an integer"
    end

    pr_comment_val = raw.key?("pr_comment") ? ActiveModel::Type::Boolean.new.cast(raw["pr_comment"]) : true

    new(
      sources: sources,
      threshold: threshold,
      on_miss: on_miss,
      hitmap_ttl_days: hitmap_ttl_days,
      pr_comment: !!pr_comment_val,
      schedule_prompt: schedule_prompt
    )
  end

  # Single canonical threshold parser shared by both parse paths — SyrusYml's
  # primary parse of the workspace's own .syrus.yml (label_prefix
  # "coverage.threshold") and .from_config's parse of .syrus.yml content read
  # from GitHub at workflow-instantiation time (label_prefix "threshold").
  # Keeping one implementation means lines/branches/pr_lines validation can't
  # silently diverge between the two paths.
  def self.parse_threshold(raw, label_prefix:)
    return nil if raw.nil?
    raise SyrusYml::ConfigError, "#{label_prefix}: must be a mapping" unless raw.is_a?(Hash)

    fields = {}
    %w[lines branches pr_lines].each do |field|
      next unless raw.key?(field)

      begin
        value = Float(raw[field])
      rescue ArgumentError, TypeError
        raise SyrusYml::ConfigError, "#{label_prefix}.#{field}: must be a number"
      end

      if value < 0 || value > 100
        raise SyrusYml::ConfigError, "#{label_prefix}.#{field}: must be between 0 and 100"
      end

      fields[field.to_sym] = value
    end

    Threshold.new(lines: fields[:lines], branches: fields[:branches], pr_lines: fields[:pr_lines])
  end

  def initialize(sources:, threshold:, on_miss:, hitmap_ttl_days:, pr_comment:, schedule_prompt:)
    @sources        = sources
    @threshold      = threshold
    @on_miss        = on_miss
    @hitmap_ttl_days = hitmap_ttl_days
    @pr_comment     = pr_comment
    @schedule_prompt = schedule_prompt
  end

  def threshold_miss?(lines_pct:, pr_delta_pct: nil)
    return false unless threshold

    lines_miss = threshold.lines && lines_pct && lines_pct < threshold.lines
    pr_miss    = threshold.pr_lines && pr_delta_pct && pr_delta_pct < threshold.pr_lines
    lines_miss || pr_miss || false
  end

  # Branch coverage is deliberately NOT part of #threshold_miss? — lines/pr_lines
  # still drive the hard `on_miss` gate (block/warn/schedule), but a branches miss
  # only ever produces a soft WorkflowWarning (see Steps::CoverageAnalyze).
  def branches_threshold_miss?(branches_pct:)
    return false unless threshold&.branches && branches_pct

    branches_pct < threshold.branches
  end

  private

  def self.parse_sources_from_config(raw)
    raise SyrusYml::ConfigError, "sources: must be an array" unless raw.is_a?(Array)
    raise SyrusYml::ConfigError, "sources: must not be empty" if raw.empty?

    raw.each_with_index.map do |item, i|
      raise SyrusYml::ConfigError, "sources[#{i}]: must be a mapping" unless item.is_a?(Hash)

      artifact = item["artifact"].to_s.strip
      raise SyrusYml::ConfigError, "sources[#{i}].artifact: is required" if artifact.empty?

      format = (item["format"] || "lcov").to_s.strip.downcase
      unless VALID_FORMATS.include?(format)
        raise SyrusYml::ConfigError, "sources[#{i}].format: must be one of #{VALID_FORMATS.join(', ')}"
      end

      Source.new(artifact: artifact, format: format)
    end
  end
end
