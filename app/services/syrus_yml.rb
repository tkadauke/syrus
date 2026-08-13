require "yaml"
require "set"

class SyrusYml
  CONFIG_FILE = ".syrus.yml".freeze
  DEFAULT_GRADE_TIMEOUT_MINUTES = 15
  MAX_GRADE_TIMEOUT_MINUTES = 60
  MIN_GRADE_MAX_ITERATIONS = 1
  MAX_GRADE_MAX_ITERATIONS = 10
  MIN_ADVERSARIAL_REVIEW_ROUNDS = 0
  MAX_ADVERSARIAL_REVIEW_ROUNDS = 10
  MIN_VISUAL_REVIEW_ROUNDS = 0
  MAX_VISUAL_REVIEW_ROUNDS = 10
  DEFAULT_VISUAL_REVIEW_ROUNDS = 1
  GRADE_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]*\z/

  COVERAGE_VALID_FORMATS = %w[lcov cobertura].freeze
  COVERAGE_VALID_ON_MISS = %w[block warn schedule].freeze
  COVERAGE_DEFAULT_ON_MISS = "warn".freeze
  COVERAGE_DEFAULT_HITMAP_TTL_DAYS = 7


  ParseError = Class.new(StandardError)
  ConfigError = Class.new(ParseError)

  DEPLOYMENT_STAGE_NAME_PATTERN = /\A[A-Za-z0-9_]+\z/

  Config = Data.define(:prepare, :grade, :hooks, :adversarial_review, :agent_insight, :coverage, :formatters, :generated, :deployment_stages, :preview, :visual_review)
  DeploymentStage = Data.define(:name, :label, :tag, :tag_pattern)
  GradeConfig = Data.define(:max_iterations, :steps)
  GradeStep = Data.define(:name, :run, :fast, :ci, :description, :required, :timeout_minutes, :when_files_changed, :junit_output)
  # Deterministic, in-place, semantics-preserving cosmetic passes (safe
  # autocorrect only). `files` are the globs this formatter owns — both its
  # target set and its self-gate (empty slice of the diff → no-op).
  FormatterStep = Data.define(:command, :files)
  # Deterministic codegen: derives checked-in `generates` outputs from `sources`
  # inputs. `codegen_ignore` marks an output committed for human reasons but
  # exempt from the `regen == committed` assertion (non-deterministic generator,
  # e.g. schema.rb across SQLite/MySQL) — grader-validated, not diff-validated.
  GeneratedStep = Data.define(:command, :sources, :generates, :codegen_ignore)
  HooksConfig = Data.define(:post_checkout)
  PreviewConfig = Data.define(:start, :setup, :seed, :health_check, :logs, :env, :unset_env)
  AdversarialReviewConfig = Data.define(:rounds, :criteria)
  VisualReviewConfig = Data.define(:enabled, :rounds, :when_files_changed, :seed_notes)
  AgentInsightConfig = Data.define(:prepare)
  # Backward-compat aliases — point to the canonical RepoCoveragePlan types so
  # existing code and specs that reference SyrusYml::CoverageConfig etc. still work.
  CoverageSource    = RepoCoveragePlan::Source
  CoverageThreshold = RepoCoveragePlan::Threshold
  CoverageConfig    = RepoCoveragePlan

  def self.load_file(path)
    new(Pathname.new(path).read).parse
  rescue Psych::SyntaxError => e
    raise ParseError, "YAML parse error: #{e.message}"
  end

  def self.load_repo(workspace_path)
    load_file(Pathname.new(workspace_path).join(CONFIG_FILE))
  end

  def initialize(contents)
    @contents = contents
  end

  def parse
    raw = YAML.safe_load(@contents, aliases: true) || {}
    raise ParseError, ".syrus.yml must be a mapping" unless raw.is_a?(Hash)

    Config.new(
      prepare: raw["prepare"],
      grade: parse_grade(raw["grade"]),
      hooks: parse_hooks(raw["hooks"]),
      adversarial_review: parse_adversarial_review(raw["adversarial_review"]),
      agent_insight: parse_agent_insight(raw["agent_insight"]),
      coverage: parse_coverage(raw["coverage"]),
      formatters: parse_formatters(raw["formatters"]),
      generated: parse_generated(raw["generated"]),
      deployment_stages: parse_deployment_stages(raw["deployment_stages"]),
      preview: parse_preview(raw["preview"]),
      visual_review: parse_visual_review(raw["visual_review"])
    )
  rescue Psych::SyntaxError => e
    raise ParseError, "YAML parse error: #{e.message}"
  end

  private

  def parse_agent_insight(raw)
    return nil if raw.nil?
    raise ParseError, "agent_insight: must be a mapping" unless raw.is_a?(Hash)

    AgentInsightConfig.new(
      prepare: ActiveModel::Type::Boolean.new.cast(raw["prepare"])
    )
  end

  def parse_formatters(raw)
    return [] if raw.nil?
    raise ParseError, "formatters: must be an array" unless raw.is_a?(Array)

    raw.each_with_index.map do |item, index|
      label = "formatters[#{index}]"
      raise ParseError, "#{label}: must be a mapping" unless item.is_a?(Hash)

      command = item["command"].to_s.strip
      raise ParseError, "#{label}.command: is required" if command.empty?

      FormatterStep.new(
        command: command,
        files: parse_globs(item["files"], "#{label}.files", required: true)
      )
    end
  end

  def parse_generated(raw)
    return [] if raw.nil?
    raise ParseError, "generated: must be an array" unless raw.is_a?(Array)

    raw.each_with_index.map do |item, index|
      label = "generated[#{index}]"
      raise ParseError, "#{label}: must be a mapping" unless item.is_a?(Hash)

      command = item["command"].to_s.strip
      raise ParseError, "#{label}.command: is required" if command.empty?

      GeneratedStep.new(
        command: command,
        sources: parse_globs(item["sources"], "#{label}.sources", required: false),
        generates: parse_globs(item["generates"], "#{label}.generates", required: true),
        codegen_ignore: item.key?("codegen_ignore") ? ActiveModel::Type::Boolean.new.cast(item["codegen_ignore"]) : false
      )
    end
  end

  # Normalizes a glob field that accepts either a single string or an array of
  # strings into a clean array of non-empty patterns.
  def parse_globs(raw, label, required:)
    globs =
      case raw
      when nil then []
      when String then [ raw ]
      when Array then raw
      else raise ParseError, "#{label}: must be a glob string or an array of globs"
      end

    globs = globs.map { |g| g.to_s.strip }.reject(&:empty?)
    raise ParseError, "#{label}: is required" if required && globs.empty?

    globs
  end

  def parse_adversarial_review(raw)
    return nil if raw.nil?
    raise ParseError, "adversarial_review: must be a mapping" unless raw.is_a?(Hash)

    unless raw.key?("rounds")
      raise ParseError, "adversarial_review.rounds: is required"
    end

    AdversarialReviewConfig.new(
      rounds: parse_adversarial_review_rounds(raw["rounds"]),
      criteria: parse_adversarial_review_criteria(raw["criteria"])
    )
  end

  # Visual review is off by default at the instance level (Feature.visual_review_enabled?);
  # a repository opts in (or explicitly opts out) per repo via this block.
  def parse_visual_review(raw)
    return nil if raw.nil?
    raise ParseError, "visual_review: must be a mapping" unless raw.is_a?(Hash)

    when_files_changed = raw["when_files_changed"]
    if !when_files_changed.nil?
      raise ParseError, "visual_review.when_files_changed: must be an array" unless when_files_changed.is_a?(Array)
      when_files_changed = when_files_changed.map { |p| p.to_s.strip }.reject(&:empty?)
    end

    VisualReviewConfig.new(
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]) || false,
      rounds: parse_visual_review_rounds(raw["rounds"]),
      when_files_changed: when_files_changed,
      seed_notes: raw["seed_notes"].to_s.strip.presence
    )
  end

  def parse_visual_review_rounds(raw)
    return DEFAULT_VISUAL_REVIEW_ROUNDS if raw.nil?

    rounds = Integer(raw)
    clamped = rounds.clamp(MIN_VISUAL_REVIEW_ROUNDS, MAX_VISUAL_REVIEW_ROUNDS)
    if clamped != rounds
      Rails.logger.warn("[SyrusYml] visual_review.rounds #{rounds} outside #{MIN_VISUAL_REVIEW_ROUNDS}..#{MAX_VISUAL_REVIEW_ROUNDS}; clamping")
    end
    clamped
  rescue ArgumentError, TypeError
    raise ParseError, "visual_review.rounds: must be an integer"
  end

  def parse_hooks(raw)
    return nil if raw.nil?
    raise ParseError, "hooks: must be a mapping" unless raw.is_a?(Hash)

    post_checkout = raw["post_checkout"]
    unless post_checkout.nil? || post_checkout.is_a?(Array)
      raise ParseError, "hooks.post_checkout: must be an array of commands"
    end

    HooksConfig.new(
      post_checkout: Array(post_checkout).map(&:to_s).map(&:strip).reject(&:empty?)
    )
  end

  def parse_grade(raw)
    return nil if raw.nil?

    case raw
    when Array
      GradeConfig.new(
        max_iterations: AppSetting.grade_max_iterations,
        steps: parse_grade_steps(raw)
      )
    when Hash
      GradeConfig.new(
        max_iterations: parse_max_iterations(raw.fetch("max_iterations", AppSetting.grade_max_iterations)),
        steps: parse_grade_steps(raw["steps"])
      )
    else
      raise ParseError, "grade: must be a mapping or an array of steps"
    end
  end

  def parse_grade_steps(raw)
    raise ParseError, "grade.steps: must be an array" unless raw.is_a?(Array)

    seen = Set.new
    raw.each_with_index.map do |step, index|
      parse_grade_step(step, index, seen)
    end
  end

  def parse_grade_step(raw, index, seen)
    label = "grade.steps[#{index}]"
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    name = raw["name"].to_s.strip
    raise ParseError, "#{label}.name: is required" if name.empty?
    raise ParseError, "#{label}.name: must match #{GRADE_NAME_PATTERN.inspect}" unless name.match?(GRADE_NAME_PATTERN)
    remember_unique_name!(seen, name, label)

    run = raw["run"].to_s.strip
    raise ParseError, "#{label}.run: is required" if run.empty?
    fast = raw["fast"].to_s.strip.presence
    ci = raw["ci"].to_s.strip.presence

    when_files_changed = raw["when_files_changed"]
    if !when_files_changed.nil?
      raise ParseError, "#{label}.when_files_changed: must be an array" unless when_files_changed.is_a?(Array)
      when_files_changed = when_files_changed.map { |p| p.to_s.strip }.reject(&:empty?)
    end

    GradeStep.new(
      name: name,
      run: run,
      fast: fast,
      ci: ci,
      description: raw["description"].to_s.strip.presence,
      required: raw.key?("required") ? ActiveModel::Type::Boolean.new.cast(raw["required"]) : true,
      timeout_minutes: parse_timeout_minutes(raw.fetch("timeout_minutes", DEFAULT_GRADE_TIMEOUT_MINUTES), name),
      when_files_changed: when_files_changed,
      junit_output: raw["junit_output"]&.to_s&.strip&.presence
    )
  end

  def parse_timeout_minutes(raw, name)
    minutes = Integer(raw)
    if minutes > MAX_GRADE_TIMEOUT_MINUTES
      Rails.logger.warn("[SyrusYml] grade step #{name.inspect} timeout_minutes #{minutes} exceeds #{MAX_GRADE_TIMEOUT_MINUTES}; clamping")
      MAX_GRADE_TIMEOUT_MINUTES
    else
      minutes
    end
  rescue ArgumentError, TypeError
    raise ParseError, "grade step #{name.inspect} timeout_minutes: must be an integer"
  end

  def parse_max_iterations(raw)
    iterations = Integer(raw)
    clamped = iterations.clamp(MIN_GRADE_MAX_ITERATIONS, MAX_GRADE_MAX_ITERATIONS)
    if clamped != iterations
      Rails.logger.warn("[SyrusYml] grade.max_iterations #{iterations} outside #{MIN_GRADE_MAX_ITERATIONS}..#{MAX_GRADE_MAX_ITERATIONS}; clamping")
    end
    clamped
  rescue ArgumentError, TypeError
    raise ParseError, "grade.max_iterations: must be an integer"
  end

  def parse_coverage(raw)
    return nil if raw.nil?
    raise ParseError, "coverage: must be a mapping" unless raw.is_a?(Hash)

    sources = parse_coverage_sources(raw["sources"])
    threshold = parse_coverage_threshold(raw["threshold"])

    on_miss = (raw["on_miss"] || COVERAGE_DEFAULT_ON_MISS).to_s.strip
    unless COVERAGE_VALID_ON_MISS.include?(on_miss)
      raise ParseError, "coverage.on_miss: must be one of #{COVERAGE_VALID_ON_MISS.join(', ')}"
    end

    hitmap_ttl_days = raw.key?("hitmap_ttl_days") ? Integer(raw["hitmap_ttl_days"]) : COVERAGE_DEFAULT_HITMAP_TTL_DAYS
    raise ParseError, "coverage.hitmap_ttl_days: must be positive" unless hitmap_ttl_days > 0

    RepoCoveragePlan.new(
      sources: sources,
      threshold: threshold,
      on_miss: on_miss,
      hitmap_ttl_days: hitmap_ttl_days,
      pr_comment: ActiveModel::Type::Boolean.new.cast(raw["pr_comment"]) || false,
      schedule_prompt: raw["schedule_prompt"].to_s.strip.presence
    )
  rescue ArgumentError, TypeError
    raise ParseError, "coverage.hitmap_ttl_days: must be an integer"
  end

  def parse_coverage_sources(raw)
    raise ParseError, "coverage.sources: must be an array" unless raw.is_a?(Array)
    raise ParseError, "coverage.sources: must not be empty" if raw.empty?

    raw.each_with_index.map do |item, index|
      label = "coverage.sources[#{index}]"
      raise ParseError, "#{label}: must be a mapping" unless item.is_a?(Hash)

      artifact = item["artifact"].to_s.strip
      raise ParseError, "#{label}.artifact: is required" if artifact.empty?

      format = item["format"].to_s.strip.downcase
      raise ParseError, "#{label}.format: must be one of #{COVERAGE_VALID_FORMATS.join(', ')}" unless COVERAGE_VALID_FORMATS.include?(format)

      RepoCoveragePlan::Source.new(artifact: artifact, format: format)
    end
  end

  def parse_coverage_threshold(raw)
    return nil if raw.nil?
    raise ParseError, "coverage.threshold: must be a mapping" unless raw.is_a?(Hash)

    lines = raw.key?("lines") ? Float(raw["lines"]) : nil
    pr_lines = raw.key?("pr_lines") ? Float(raw["pr_lines"]) : nil

    if lines && (lines < 0 || lines > 100)
      raise ParseError, "coverage.threshold.lines: must be between 0 and 100"
    end
    if pr_lines && (pr_lines < 0 || pr_lines > 100)
      raise ParseError, "coverage.threshold.pr_lines: must be between 0 and 100"
    end

    RepoCoveragePlan::Threshold.new(lines: lines, branches: nil, pr_lines: pr_lines)
  rescue ArgumentError, TypeError
    raise ParseError, "coverage.threshold: lines and pr_lines must be numbers"
  end

  def parse_adversarial_review_criteria(raw)
    return [] if raw.nil?
    raise ParseError, "adversarial_review.criteria: must be an array of strings" unless raw.is_a?(Array)

    raw.map { |item| item.to_s.strip }.reject(&:empty?)
  end

  def parse_preview(raw)
    return nil if raw.nil?
    raise ParseError, "preview: must be a mapping" unless raw.is_a?(Hash)

    start = raw["start"].to_s.strip
    raise ParseError, "preview.start: is required" if start.empty?

    PreviewConfig.new(
      start:        start,
      setup:        parse_preview_commands(raw["setup"], "preview.setup"),
      seed:         raw["seed"].to_s.strip.presence,
      health_check: raw["health_check"].to_s.strip.presence || "/",
      logs:         Array(raw["logs"]).map { |p| p.to_s.strip }.reject(&:empty?),
      env:          parse_preview_env(raw["env"]),
      unset_env:    parse_preview_unset_env(raw["unset_env"])
    )
  end

  def parse_preview_env(raw)
    return {} if raw.nil?
    raise ParseError, "preview.env: must be a mapping" unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(key, value), env|
      name = key.to_s.strip
      raise ParseError, "preview.env: contains a blank key" if name.empty?
      env[name] = value.to_s
    end
  end

  def parse_preview_commands(raw, label)
    case raw
    when nil then []
    when String then [ raw.to_s.strip ].reject(&:empty?)
    when Array then raw.map { |command| command.to_s.strip }.reject(&:empty?)
    else raise ParseError, "#{label}: must be a string or an array of commands"
    end
  end

  def parse_preview_unset_env(raw)
    return [] if raw.nil?
    values =
      case raw
      when String then [ raw ]
      when Array then raw
      else raise ParseError, "preview.unset_env: must be a string or an array of strings"
      end

    values.map { |name| name.to_s.strip }.reject(&:empty?)
  end

  def parse_adversarial_review_rounds(raw)
    rounds = Integer(raw)
    clamped = rounds.clamp(MIN_ADVERSARIAL_REVIEW_ROUNDS, MAX_ADVERSARIAL_REVIEW_ROUNDS)
    if clamped != rounds
      Rails.logger.warn("[SyrusYml] adversarial_review.rounds #{rounds} outside #{MIN_ADVERSARIAL_REVIEW_ROUNDS}..#{MAX_ADVERSARIAL_REVIEW_ROUNDS}; clamping")
    end
    clamped
  rescue ArgumentError, TypeError
    raise ParseError, "adversarial_review.rounds: must be an integer"
  end

  def parse_deployment_stages(raw)
    return [] if raw.nil?
    raise ParseError, "deployment_stages: must be an array" unless raw.is_a?(Array)

    seen = Set.new
    raw.each_with_index.map do |item, index|
      parse_deployment_stage(item, index, seen)
    end
  end

  def parse_deployment_stage(raw, index, seen)
    label = "deployment_stages[#{index}]"
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    name = raw["name"].to_s.strip
    raise ParseError, "#{label}.name: is required" if name.empty?
    unless name.match?(DEPLOYMENT_STAGE_NAME_PATTERN)
      raise ParseError, "#{label}.name: must contain only alphanumeric characters and underscores"
    end
    remember_unique_name!(seen, name, label)

    tag = raw["tag"].to_s.strip.presence
    tag_pattern = raw["tag_pattern"].to_s.strip.presence

    if tag.nil? && tag_pattern.nil?
      raise ParseError, "#{label}: must specify either 'tag' or 'tag_pattern'"
    end
    if tag && tag_pattern
      raise ParseError, "#{label}: cannot specify both 'tag' and 'tag_pattern'"
    end

    display_label = raw["label"].to_s.strip.presence || name.tr("_", " ").split.map(&:capitalize).join(" ")

    DeploymentStage.new(name: name, label: display_label, tag: tag, tag_pattern: tag_pattern)
  end

  def remember_unique_name!(seen, name, label)
    raise ParseError, "#{label}.name: #{name.inspect} is duplicated" if seen.include?(name)

    seen << name
  end
end
