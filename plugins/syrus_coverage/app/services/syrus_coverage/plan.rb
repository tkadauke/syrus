class SyrusCoverage::Plan
  Source    = Data.define(:artifact, :format)
  Threshold = Data.define(:lines, :branches, :pr_lines)

  VALID_ON_MISS        = %w[block warn schedule].freeze
  VALID_FORMATS        = %w[lcov cobertura go-cover].freeze
  DEFAULT_ON_MISS      = "warn".freeze
  DEFAULT_HITMAP_TTL_DAYS = 7

  attr_reader :sources, :threshold, :on_miss, :hitmap_ttl_days, :pr_comment, :schedule_prompt,
    :project_id, :project_label, :project_path, :owner_config_path, :coverage_base_path, :target_label

  def self.for(workspace_path)
    path = Pathname.new(workspace_path)
    return nil unless path.join(SyrusYml::CONFIG_FILE).exist?

    SyrusYml.load_repo(path).plugin_configurations[SyrusCoverage::RepositoryConfiguration::KEY]
  rescue SyrusYml::ParseError => e
    Rails.logger.warn("[SyrusCoverage::Plan] .syrus.yml parse error: #{e.message}")
    nil
  end

  # Validates the `threshold:` mapping (lines/branches/pr_lines, each 0..100).
  def self.parse_threshold(raw, label_prefix:)
    return nil if raw.nil?
    raise SyrusYml::ParseError, "#{label_prefix}: must be a mapping" unless raw.is_a?(Hash)

    fields = {}
    %w[lines branches pr_lines].each do |field|
      next unless raw.key?(field)

      begin
        value = Float(raw[field])
      rescue ArgumentError, TypeError
        raise SyrusYml::ParseError, "#{label_prefix}.#{field}: must be a number"
      end

      if value < 0 || value > 100
        raise SyrusYml::ParseError, "#{label_prefix}.#{field}: must be between 0 and 100"
      end

      fields[field.to_sym] = value
    end

    Threshold.new(lines: fields[:lines], branches: fields[:branches], pr_lines: fields[:pr_lines])
  end

  def initialize(sources:, threshold:, on_miss:, hitmap_ttl_days:, pr_comment:, schedule_prompt:,
    project_id: SyrusCoverage.root_project_id, project_label: "Repository", project_path: "",
    owner_config_path: SyrusYml::CONFIG_FILE, coverage_base_path: nil, target_label: nil)
    @sources        = sources
    @threshold      = threshold
    @on_miss        = on_miss
    @hitmap_ttl_days = hitmap_ttl_days
    @pr_comment     = pr_comment
    @schedule_prompt = schedule_prompt
    @project_id = project_id.to_s
    @project_label = project_label.to_s.presence || @project_id
    @project_path = project_path.to_s
    @owner_config_path = owner_config_path&.to_s
    @coverage_base_path = coverage_base_path.nil? ? coverage_base_path_for(@owner_config_path) : coverage_base_path.to_s
    @target_label = target_label&.to_s || coverage_target_label(@coverage_base_path)
  end

  def with_project(project)
    self.class.new(
      sources: sources,
      threshold: threshold,
      on_miss: on_miss,
      hitmap_ttl_days: hitmap_ttl_days,
      pr_comment: pr_comment,
      schedule_prompt: schedule_prompt,
      project_id: project.id,
      project_label: project.label,
      project_path: project.path,
      owner_config_path: project.owner_config_path,
      coverage_base_path: coverage_base_path_for(project.owner_config_path)
    )
  end

  def threshold_miss?(lines_pct:, pr_delta_pct: nil)
    return false unless threshold

    lines_miss = threshold.lines && lines_pct && lines_pct < threshold.lines
    pr_miss    = threshold.pr_lines && pr_delta_pct && pr_delta_pct < threshold.pr_lines
    lines_miss || pr_miss || false
  end

  # Branch coverage is deliberately NOT part of #threshold_miss? — lines/pr_lines
  # still drive the hard `on_miss` gate (block/warn/schedule), but a branches miss
  # only ever produces a soft WorkflowWarning (see SyrusCoverage::AnalyzeStep).
  def branches_threshold_miss?(branches_pct:)
    return false unless threshold&.branches && branches_pct

    branches_pct < threshold.branches
  end

  def root_project?
    project_path.blank?
  end

  private

  def coverage_target_label(path)
    package = path.to_s
    package.present? ? "//#{package}:coverage" : "//:coverage"
  end

  def coverage_base_path_for(owner_config_path)
    path = owner_config_path.to_s
    return "" if path.blank? || path == SyrusYml::CONFIG_FILE

    File.dirname(path)
  end
end
