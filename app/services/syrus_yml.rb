require "yaml"
require "set"

class SyrusYml
  CONFIG_FILE = ".syrus.yml".freeze
  DEFAULT_GRADE_TIMEOUT_MINUTES = 15
  # Was 60; this repo's own .syrus.yml declares timeout_minutes: 75 for the
  # rspec grader (serial suite growth), but the old ceiling silently clamped
  # that back down to 60 and produced spurious exit-124 timeouts with 0
  # actual failures. Keep this above the largest legitimate timeout_minutes
  # in use.
  MAX_GRADE_TIMEOUT_MINUTES = 90
  MIN_GRADE_MAX_ITERATIONS = 1
  MAX_GRADE_MAX_ITERATIONS = 10
  MIN_ADVERSARIAL_REVIEW_ROUNDS = 0
  MAX_ADVERSARIAL_REVIEW_ROUNDS = 10
  MIN_VISUAL_REVIEW_ROUNDS = 0
  MAX_VISUAL_REVIEW_ROUNDS = 10
  DEFAULT_VISUAL_REVIEW_ROUNDS = 1
  GRADE_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]*\z/
  GRADE_FAILURE_POLICIES = %w[strict allow_inherited].freeze
  DEFAULT_GRADE_FAILURE_POLICY = "strict".freeze
  GRADE_PHASES = %w[review landing ci].freeze
  DEFAULT_GRADE_PHASES = GRADE_PHASES.freeze

  COVERAGE_VALID_FORMATS = %w[lcov cobertura].freeze
  COVERAGE_VALID_ON_MISS = %w[block warn schedule].freeze
  COVERAGE_DEFAULT_ON_MISS = "warn".freeze
  COVERAGE_DEFAULT_HITMAP_TTL_DAYS = 7

  DEPLOY_MODES = %w[manual continuous].freeze
  DEFAULT_DEPLOY_MODE = "manual".freeze

  DELIVERY_NAME_PATTERN = /\A[A-Za-z0-9_]+\z/
  DEFAULT_DELIVERY_TRACK_NAME = "default".freeze
  DEFAULT_DELIVERY_REVIEW_PHASE = "review".freeze
  DEFAULT_DELIVERY_LANDING_PHASE = "landing".freeze
  DEFAULT_DELIVERY_CI_FAILURE_PHASE = "ci".freeze
  DEFAULT_DELIVERY_BRANCH_HEALTH_PHASE = "ci".freeze
  DELIVERY_PROMOTION_MODES = %w[direct auto_pr manual_pr].freeze
  DEFAULT_DELIVERY_PROMOTION_MODE = "auto_pr".freeze
  DELIVERY_HOTFIX_SYNC_MODES = %w[auto auto_pr manual_pr].freeze
  DEFAULT_DELIVERY_HOTFIX_SYNC_MODE = "auto".freeze
  DELIVERY_HOTFIX_SYNC_DIRECTIONS = %w[release_to_development].freeze
  DEFAULT_DELIVERY_HOTFIX_SYNC_DIRECTION = "release_to_development".freeze
  DELIVERY_UPSTREAM_EXPORT_MODES = %w[per_job_pr branch_pr].freeze
  DEFAULT_DELIVERY_UPSTREAM_EXPORT_MODE = "per_job_pr".freeze
  DELIVERY_REF_MOVEMENT_MODES = %w[direct auto_pr manual_pr].freeze

  ParseError = Class.new(StandardError)
  ConfigError = Class.new(ParseError)

  DEPLOYMENT_STAGE_NAME_PATTERN = /\A[A-Za-z0-9_]+\z/

  Config = Data.define(:prepare, :grade, :hooks, :adversarial_review, :agent_insight, :coverage, :formatters, :generated, :deployment_stages, :preview, :visual_review, :review_plan, :deploy, :delivery, :raw_delivery, :approval)
  DeploymentStage = Data.define(:name, :label, :tag, :tag_pattern)
  # `run` is a required shell command — a `deploy:` block with no `run` is a
  # parse error, not a silent no-op, since (unlike `prepare`) there is no
  # auto-detected fallback for a deploy command. `mode` is `"manual"`
  # (default, launched on demand via the Job's Deploy action) or
  # `"continuous"` (auto-triggered after a landing Workflow succeeds).
  # `min_interval_minutes` only matters in continuous mode (throttles
  # auto-triggered deploys); parsed here as a plain positive integer, not a
  # duration string, matching `timeout_minutes`/`hitmap_ttl_days` elsewhere
  # in this file.
  DeployConfig = Data.define(:mode, :run, :allow_unapproved, :min_interval_minutes)
  # Modeled on docs/plans/delivery-tracks-and-promotion.md. `delivery:` is
  # optional the same way `deploy:`/`formatters:`/`generated:` are: absence
  # means "current behavior," never a parse error.
  #
  # `Config#raw_delivery` is exactly what `.syrus.yml` declared (nil when the
  # `delivery:` key is absent entirely) — kept for display/debugging so an
  # operator can see the repository's literal config. `Config#delivery` is
  # always present and normalized per the plan's "Backward Compatibility And
  # Defaults" section, so runtime code never has to branch on "missing
  # delivery block." One thing normalization can NOT do here: resolve a
  # track's blank `branch` to the repository's default branch, because
  # `SyrusYml` only ever sees file content, never a `Repository`. A blank
  # `DeliveryTrack#branch` means "use `Repository#default_branch`" and is
  # resolved by `DeliveryPolicy`, which does have repository context.
  DeliveryTrack = Data.define(:name, :branch, :review_grade_phase, :landing_grade_phase, :ci_failure_grade_phase, :branch_health_grade_phase, :after_landing_sync_to)
  DeliveryPromotionConfig = Data.define(:enabled, :mode, :approval_required, :grade_phases, :repair_skill)
  DeliveryHotfixSyncConfig = Data.define(:enabled, :direction, :mode, :grade_phases, :repair_skill)
  DeliveryUpstreamExportConfig = Data.define(:enabled, :mode, :after_local_approval, :target)
  # `kind` names what `source`/`target` resolve to (`job_branch`, `track`,
  # `branch`, `upstream_intake`, ...); `name` is the track/branch name when
  # `kind` needs one (e.g. `{ kind: track, name: default }`) and is nil
  # otherwise. Not enum-checked: the plan's own "Later Additions" section
  # expects new kinds (versioned release branches, patch-queue transports)
  # without a parser change.
  DeliveryRefEndpoint = Data.define(:kind, :name)
  DeliveryRefMovementAction = Data.define(:name, :enabled, :source, :target, :mode, :grade_phases)
  DeliveryConfig = Data.define(:tracks, :promotion, :hotfix_sync, :upstream_export, :ref_movement_actions)
  # Modeled on docs/plans/delivery-tracks-and-promotion.md Story 7 (owner +
  # peer local approval, optional promotion maintainer approval). Unlike
  # `Config#delivery`, `Config#approval` is left nil when the `approval:` key
  # is absent -- there is no normalized always-present shape here, because
  # "no `approval:` section" is itself a meaningful signal: it means "use the
  # repository's existing `review_policy` behavior" (see `DeliveryPolicy`),
  # not "use some default owner/peer_count combination." `owner_required`
  # and `peer_count` are individually nilable too, so a config that sets only
  # one of `approval.job.required.owner` / `.peer_count` doesn't silently
  # zero out the other.
  ApprovalConfig = Data.define(:job, :promotion)
  ApprovalJobConfig = Data.define(:owner_required, :peer_count)
  ApprovalPromotionConfig = Data.define(:maintainer_count)
  GradeConfig = Data.define(:max_iterations, :failures, :steps)
  # `ci` is accepted for compatibility: RepoGradePlan expands legacy `ci:`
  # into a synthetic `*-ci` grader in the `ci` phase. Runtime grading
  # otherwise selects configured grader entries by `phases`.
  GradeStep = Data.define(:name, :run, :ci, :phases, :description, :required, :timeout_minutes, :when_files_changed, :junit_output, :failures)
  # Deterministic, in-place, semantics-preserving cosmetic passes (safe
  # autocorrect only). `files` are the globs this formatter owns — both its
  # target set and its self-gate (empty slice of the diff → no-op).
  #
  # `Config#formatters` is tri-state: `nil` when the `formatters:` key is
  # absent (Steps::Format runs no formatting at all — the safe default),
  # `false` when explicitly disabled (`formatters: false`/`off` — no
  # formatting at all, including plugin defaults), or an `Array` of
  # `FormatterStep` when explicitly configured — an empty `Array`
  # (`formatters: []`) is the opt-in signal for Steps::Format to fall back
  # to plugin-provided `:autofix_command` defaults, while a populated
  # `Array` runs those explicit commands instead.
  FormatterStep = Data.define(:command, :files)
  # Deterministic codegen: derives checked-in `generates` outputs from `sources`
  # inputs. `codegen_ignore` marks an output committed for human reasons but
  # exempt from the `regen == committed` assertion (non-deterministic generator,
  # e.g. schema.rb across SQLite/MySQL) — grader-validated, not diff-validated;
  # Steps::Generate also skips running these entries itself, since forcing a
  # non-deterministic regen and committing the result would introduce
  # environment-specific noise rather than fix anything.
  #
  # `Config#generated` follows the same tri-state as `formatters` above:
  # `nil` when absent (Steps::Generate no-ops — there is no plugin-provided
  # codegen default), `false` when explicitly disabled, or an `Array` of
  # `GeneratedStep` when explicitly configured.
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

    raw_delivery = parse_delivery(raw["delivery"])

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
      visual_review: parse_visual_review(raw["visual_review"]),
      review_plan: ActiveModel::Type::Boolean.new.cast(raw["review_plan"]) || false,
      deploy: parse_deploy(raw["deploy"]),
      delivery: normalize_delivery(raw_delivery),
      raw_delivery: raw_delivery,
      approval: parse_approval(raw["approval"])
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
    return nil if raw.nil?
    return false if raw == false

    raise ParseError, "formatters: must be an array, or false/off to disable" unless raw.is_a?(Array)

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
    return nil if raw.nil?
    return false if raw == false

    raise ParseError, "generated: must be an array, or false/off to disable" unless raw.is_a?(Array)

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
      # No `|| false` here on purpose: nil (the `enabled` key omitted, or
      # explicitly set to `null`/blank) must stay nil so callers can
      # distinguish "not specified — defer to Feature.visual_review_enabled?"
      # from an explicit `enabled: false` repo override. Any other present
      # value is cast to a real boolean by ActiveModel::Type::Boolean (only
      # its recognized false-spellings — "false", "0", "f", etc. — cast to
      # false; every other non-blank value, including unrecognized strings,
      # casts to true).
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]),
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
        failures: DEFAULT_GRADE_FAILURE_POLICY,
        steps: parse_grade_steps(raw)
      )
    when Hash
      failures = parse_grade_failure_policy(raw.fetch("failures", DEFAULT_GRADE_FAILURE_POLICY), "grade.failures")
      GradeConfig.new(
        max_iterations: parse_max_iterations(raw.fetch("max_iterations", AppSetting.grade_max_iterations)),
        failures: failures,
        steps: parse_grade_steps(raw["steps"], default_failures: failures)
      )
    else
      raise ParseError, "grade: must be a mapping or an array of steps"
    end
  end

  def parse_grade_steps(raw, default_failures: DEFAULT_GRADE_FAILURE_POLICY)
    raise ParseError, "grade.steps: must be an array" unless raw.is_a?(Array)

    seen = Set.new
    raw.each_with_index.map do |step, index|
      parse_grade_step(step, index, seen, default_failures: default_failures)
    end
  end

  def parse_grade_step(raw, index, seen, default_failures:)
    label = "grade.steps[#{index}]"
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    name = raw["name"].to_s.strip
    raise ParseError, "#{label}.name: is required" if name.empty?
    raise ParseError, "#{label}.name: must match #{GRADE_NAME_PATTERN.inspect}" unless name.match?(GRADE_NAME_PATTERN)
    remember_unique_name!(seen, name, label)

    run = raw["run"].to_s.strip
    raise ParseError, "#{label}.run: is required" if run.empty?
    ci = raw["ci"].to_s.strip.presence
    phases = parse_grade_phases(raw["phases"], "#{label}.phases")

    when_files_changed = raw["when_files_changed"]
    if !when_files_changed.nil?
      raise ParseError, "#{label}.when_files_changed: must be an array" unless when_files_changed.is_a?(Array)
      when_files_changed = when_files_changed.map { |p| p.to_s.strip }.reject(&:empty?)
    end

    GradeStep.new(
      name: name,
      run: run,
      ci: ci,
      phases: phases,
      description: raw["description"].to_s.strip.presence,
      required: raw.key?("required") ? ActiveModel::Type::Boolean.new.cast(raw["required"]) : true,
      timeout_minutes: parse_timeout_minutes(raw.fetch("timeout_minutes", DEFAULT_GRADE_TIMEOUT_MINUTES), name),
      when_files_changed: when_files_changed,
      junit_output: raw["junit_output"]&.to_s&.strip&.presence,
      failures: parse_grade_failure_policy(raw.fetch("failures", default_failures), "grade step #{name.inspect} failures")
    )
  end

  def parse_grade_failure_policy(raw, label)
    value = raw.to_s.strip.presence
    return DEFAULT_GRADE_FAILURE_POLICY if value.blank?
    return value if value.in?(GRADE_FAILURE_POLICIES)

    raise ParseError, "#{label}: must be one of #{GRADE_FAILURE_POLICIES.join(', ')}"
  end

  def parse_grade_phases(raw, label)
    phases =
      case raw
      when nil then DEFAULT_GRADE_PHASES
      when String then [ raw ]
      when Array then raw
      else raise ParseError, "#{label}: must be a phase string or an array of phase strings"
      end

    phases = phases.map { |phase| phase.to_s.strip }.reject(&:empty?).uniq
    raise ParseError, "#{label}: must not be empty" if phases.empty?

    invalid = phases - GRADE_PHASES
    raise ParseError, "#{label}: must contain only #{GRADE_PHASES.join(', ')}" if invalid.any?

    phases
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

  # Delegates to RepoCoveragePlan's shared parser so this primary parse path
  # (reading the workspace's own .syrus.yml) and .from_config's GitHub-content
  # parse path can't silently diverge on lines/branches/pr_lines validation.
  # ConfigError is a subclass of ParseError, so callers that rescue ParseError
  # see no behavior change.
  def parse_coverage_threshold(raw)
    RepoCoveragePlan.parse_threshold(raw, label_prefix: "coverage.threshold")
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

  # Independent trigger mechanism from `deployment_stages` above: this
  # configures Syrus to actually *run* a deploy command (manual button or
  # continuous auto-trigger), not to track a read-only tag against an
  # external pipeline. Omitting `deploy:` disables the feature for the
  # repository — same safe-default posture as `formatters:`/`generated:`.
  def parse_deploy(raw)
    return nil if raw.nil?
    raise ParseError, "deploy: must be a mapping" unless raw.is_a?(Hash)

    run = raw["run"].to_s.strip
    raise ParseError, "deploy.run: is required" if run.empty?

    mode = raw.key?("mode") ? raw["mode"].to_s.strip : DEFAULT_DEPLOY_MODE
    raise ParseError, "deploy.mode: must be one of #{DEPLOY_MODES.join(', ')}" unless DEPLOY_MODES.include?(mode)

    DeployConfig.new(
      mode: mode,
      run: run,
      allow_unapproved: ActiveModel::Type::Boolean.new.cast(raw["allow_unapproved"]) || false,
      min_interval_minutes: parse_deploy_min_interval_minutes(raw["min_interval_minutes"])
    )
  end

  def parse_deploy_min_interval_minutes(raw)
    return nil if raw.nil?

    minutes = Integer(raw)
    raise ParseError, "deploy.min_interval_minutes: must be a positive integer" unless minutes.positive?

    minutes
  rescue ArgumentError, TypeError
    raise ParseError, "deploy.min_interval_minutes: must be a positive integer"
  end

  def parse_delivery(raw)
    return nil if raw.nil?
    raise ParseError, "delivery: must be a mapping" unless raw.is_a?(Hash)

    DeliveryConfig.new(
      tracks: raw.key?("tracks") ? parse_delivery_tracks(raw["tracks"]) : nil,
      promotion: parse_delivery_promotion(raw["promotion"]),
      hotfix_sync: parse_delivery_hotfix_sync(raw["hotfix_sync"]),
      upstream_export: parse_delivery_upstream_export(raw["upstream_export"]),
      ref_movement_actions: raw.key?("ref_movement_actions") ? parse_delivery_ref_movement_actions(raw["ref_movement_actions"]) : nil
    )
  end

  # Fills in the plan's "Backward Compatibility And Defaults" shape so
  # `Config#delivery` is always usable without a nil check, whether
  # `delivery:` was absent entirely or present but missing some sub-blocks.
  def normalize_delivery(raw_delivery)
    DeliveryConfig.new(
      tracks: raw_delivery&.tracks || default_delivery_tracks,
      promotion: raw_delivery&.promotion || default_delivery_promotion,
      hotfix_sync: raw_delivery&.hotfix_sync || default_delivery_hotfix_sync,
      upstream_export: raw_delivery&.upstream_export || default_delivery_upstream_export,
      ref_movement_actions: raw_delivery&.ref_movement_actions || {}
    )
  end

  def default_delivery_tracks
    {
      DEFAULT_DELIVERY_TRACK_NAME => DeliveryTrack.new(
        name: DEFAULT_DELIVERY_TRACK_NAME,
        branch: nil,
        review_grade_phase: DEFAULT_DELIVERY_REVIEW_PHASE,
        landing_grade_phase: DEFAULT_DELIVERY_LANDING_PHASE,
        ci_failure_grade_phase: DEFAULT_DELIVERY_CI_FAILURE_PHASE,
        branch_health_grade_phase: DEFAULT_DELIVERY_BRANCH_HEALTH_PHASE,
        after_landing_sync_to: nil
      )
    }
  end

  def default_delivery_promotion
    DeliveryPromotionConfig.new(enabled: false, mode: DEFAULT_DELIVERY_PROMOTION_MODE, approval_required: false, grade_phases: [], repair_skill: nil)
  end

  def default_delivery_hotfix_sync
    DeliveryHotfixSyncConfig.new(enabled: false, direction: DEFAULT_DELIVERY_HOTFIX_SYNC_DIRECTION, mode: DEFAULT_DELIVERY_HOTFIX_SYNC_MODE, grade_phases: [], repair_skill: nil)
  end

  def default_delivery_upstream_export
    DeliveryUpstreamExportConfig.new(enabled: false, mode: DEFAULT_DELIVERY_UPSTREAM_EXPORT_MODE, after_local_approval: true, target: nil)
  end

  def parse_delivery_tracks(raw)
    raise ParseError, "delivery.tracks: must be a mapping" unless raw.is_a?(Hash)
    unless raw.key?(DEFAULT_DELIVERY_TRACK_NAME)
      raise ParseError, "delivery.tracks: must include a #{DEFAULT_DELIVERY_TRACK_NAME.inspect} track"
    end

    raw.each_with_object({}) do |(name, track_raw), tracks|
      label = "delivery.tracks.#{name}"
      key = name.to_s.strip
      raise ParseError, "#{label}: name must not be blank" if key.empty?
      raise ParseError, "#{label}: name must match #{DELIVERY_NAME_PATTERN.inspect}" unless key.match?(DELIVERY_NAME_PATTERN)

      tracks[key] = parse_delivery_track(key, track_raw, label)
    end
  end

  def parse_delivery_track(name, raw, label)
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    grade_phases = raw["grade_phases"]
    raise ParseError, "#{label}.grade_phases: must be a mapping" unless grade_phases.nil? || grade_phases.is_a?(Hash)
    grade_phases ||= {}

    after_landing = raw["after_landing"]
    raise ParseError, "#{label}.after_landing: must be a mapping" unless after_landing.nil? || after_landing.is_a?(Hash)

    DeliveryTrack.new(
      name: name,
      branch: raw["branch"].to_s.strip.presence,
      review_grade_phase: grade_phases["review"].to_s.strip.presence || DEFAULT_DELIVERY_REVIEW_PHASE,
      landing_grade_phase: grade_phases["landing"].to_s.strip.presence || DEFAULT_DELIVERY_LANDING_PHASE,
      ci_failure_grade_phase: grade_phases["ci_failure"].to_s.strip.presence || DEFAULT_DELIVERY_CI_FAILURE_PHASE,
      branch_health_grade_phase: grade_phases["branch_health"].to_s.strip.presence || DEFAULT_DELIVERY_BRANCH_HEALTH_PHASE,
      after_landing_sync_to: after_landing && after_landing["sync_to"].to_s.strip.presence
    )
  end

  def parse_delivery_promotion(raw)
    return nil if raw.nil?
    raise ParseError, "delivery.promotion: must be a mapping" unless raw.is_a?(Hash)

    mode = raw.key?("mode") ? raw["mode"].to_s.strip : DEFAULT_DELIVERY_PROMOTION_MODE
    unless DELIVERY_PROMOTION_MODES.include?(mode)
      raise ParseError, "delivery.promotion.mode: must be one of #{DELIVERY_PROMOTION_MODES.join(', ')}"
    end

    DeliveryPromotionConfig.new(
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]) || false,
      mode: mode,
      approval_required: ActiveModel::Type::Boolean.new.cast(raw["approval_required"]) || false,
      grade_phases: parse_delivery_phase_list(raw["grade_phases"], "delivery.promotion.grade_phases"),
      repair_skill: raw["repair_skill"].to_s.strip.presence
    )
  end

  def parse_delivery_hotfix_sync(raw)
    return nil if raw.nil?
    raise ParseError, "delivery.hotfix_sync: must be a mapping" unless raw.is_a?(Hash)

    direction = raw.key?("direction") ? raw["direction"].to_s.strip : DEFAULT_DELIVERY_HOTFIX_SYNC_DIRECTION
    unless DELIVERY_HOTFIX_SYNC_DIRECTIONS.include?(direction)
      raise ParseError, "delivery.hotfix_sync.direction: must be one of #{DELIVERY_HOTFIX_SYNC_DIRECTIONS.join(', ')}"
    end

    mode = raw.key?("mode") ? raw["mode"].to_s.strip : DEFAULT_DELIVERY_HOTFIX_SYNC_MODE
    unless DELIVERY_HOTFIX_SYNC_MODES.include?(mode)
      raise ParseError, "delivery.hotfix_sync.mode: must be one of #{DELIVERY_HOTFIX_SYNC_MODES.join(', ')}"
    end

    DeliveryHotfixSyncConfig.new(
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]) || false,
      direction: direction,
      mode: mode,
      grade_phases: parse_delivery_phase_list(raw["grade_phases"], "delivery.hotfix_sync.grade_phases"),
      repair_skill: raw["repair_skill"].to_s.strip.presence
    )
  end

  def parse_delivery_upstream_export(raw)
    return nil if raw.nil?
    raise ParseError, "delivery.upstream_export: must be a mapping" unless raw.is_a?(Hash)

    mode = raw.key?("mode") ? raw["mode"].to_s.strip : DEFAULT_DELIVERY_UPSTREAM_EXPORT_MODE
    unless DELIVERY_UPSTREAM_EXPORT_MODES.include?(mode)
      raise ParseError, "delivery.upstream_export.mode: must be one of #{DELIVERY_UPSTREAM_EXPORT_MODES.join(', ')}"
    end

    DeliveryUpstreamExportConfig.new(
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]) || false,
      mode: mode,
      after_local_approval: raw.key?("after_local_approval") ? ActiveModel::Type::Boolean.new.cast(raw["after_local_approval"]) : true,
      target: raw["target"].to_s.strip.presence
    )
  end

  def parse_delivery_ref_movement_actions(raw)
    raise ParseError, "delivery.ref_movement_actions: must be a mapping" unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(name, action_raw), actions|
      label = "delivery.ref_movement_actions.#{name}"
      key = name.to_s.strip
      raise ParseError, "#{label}: name must not be blank" if key.empty?
      raise ParseError, "#{label}: name must match #{DELIVERY_NAME_PATTERN.inspect}" unless key.match?(DELIVERY_NAME_PATTERN)

      actions[key] = parse_delivery_ref_movement_action(key, action_raw, label)
    end
  end

  def parse_delivery_ref_movement_action(name, raw, label)
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    mode = raw["mode"].to_s.strip
    raise ParseError, "#{label}.mode: is required" if mode.empty?
    raise ParseError, "#{label}.mode: must be one of #{DELIVERY_REF_MOVEMENT_MODES.join(', ')}" unless DELIVERY_REF_MOVEMENT_MODES.include?(mode)

    DeliveryRefMovementAction.new(
      name: name,
      enabled: ActiveModel::Type::Boolean.new.cast(raw["enabled"]) || false,
      source: parse_delivery_ref_endpoint(raw["source"], "#{label}.source"),
      target: parse_delivery_ref_endpoint(raw["target"], "#{label}.target"),
      mode: mode,
      grade_phases: parse_delivery_phase_list(raw["grade_phases"], "#{label}.grade_phases")
    )
  end

  def parse_delivery_ref_endpoint(raw, label)
    raise ParseError, "#{label}: is required" if raw.nil?
    raise ParseError, "#{label}: must be a mapping" unless raw.is_a?(Hash)

    kind = raw["kind"].to_s.strip
    raise ParseError, "#{label}.kind: is required" if kind.empty?

    DeliveryRefEndpoint.new(kind: kind, name: raw["name"].to_s.strip.presence)
  end

  def parse_delivery_phase_list(raw, label)
    phases =
      case raw
      when nil then []
      when String then [ raw ]
      when Array then raw
      else raise ParseError, "#{label}: must be a phase name string or an array of phase name strings"
      end

    phases.map { |phase| phase.to_s.strip }.reject(&:empty?)
  end

  def parse_approval(raw)
    return nil if raw.nil?
    raise ParseError, "approval: must be a mapping" unless raw.is_a?(Hash)

    ApprovalConfig.new(
      job: parse_approval_job(raw["job"]),
      promotion: parse_approval_promotion(raw["promotion"])
    )
  end

  def parse_approval_job(raw)
    return nil if raw.nil?
    raise ParseError, "approval.job: must be a mapping" unless raw.is_a?(Hash)

    required = raw["required"]
    raise ParseError, "approval.job.required: must be a mapping" unless required.nil? || required.is_a?(Hash)
    required ||= {}

    ApprovalJobConfig.new(
      owner_required: required.key?("owner") ? ActiveModel::Type::Boolean.new.cast(required["owner"]) : nil,
      peer_count: required.key?("peer_count") ? parse_non_negative_integer(required["peer_count"], "approval.job.required.peer_count") : nil
    )
  end

  def parse_approval_promotion(raw)
    return nil if raw.nil?
    raise ParseError, "approval.promotion: must be a mapping" unless raw.is_a?(Hash)

    required = raw["required"]
    raise ParseError, "approval.promotion.required: must be a mapping" unless required.nil? || required.is_a?(Hash)
    required ||= {}

    ApprovalPromotionConfig.new(
      maintainer_count: required.key?("maintainer_count") ? parse_non_negative_integer(required["maintainer_count"], "approval.promotion.required.maintainer_count") : nil
    )
  end

  def parse_non_negative_integer(raw, label)
    value = Integer(raw)
    raise ParseError, "#{label}: must not be negative" if value.negative?

    value
  rescue ArgumentError, TypeError
    raise ParseError, "#{label}: must be an integer"
  end

  def remember_unique_name!(seen, name, label)
    raise ParseError, "#{label}.name: #{name.inspect} is duplicated" if seen.include?(name)

    seen << name
  end
end
