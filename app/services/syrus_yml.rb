require "yaml"
require "set"

class SyrusYml
  CONFIG_FILE = ".syrus.yml".freeze
  DEFAULT_GRADE_TIMEOUT_MINUTES = 15
  MAX_GRADE_TIMEOUT_MINUTES = 30
  MIN_GRADE_MAX_ITERATIONS = 1
  MAX_GRADE_MAX_ITERATIONS = 10
  GRADE_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]*\z/

  ParseError = Class.new(StandardError)

  Config = Data.define(:prepare, :grade, :hooks)
  GradeConfig = Data.define(:max_iterations, :steps)
  GradeStep = Data.define(:name, :run, :description, :required, :timeout_minutes)
  HooksConfig = Data.define(:post_checkout)

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
    raw = YAML.safe_load(@contents) || {}
    raise ParseError, ".syrus.yml must be a mapping" unless raw.is_a?(Hash)

    Config.new(
      prepare: raw["prepare"],
      grade: parse_grade(raw["grade"]),
      hooks: parse_hooks(raw["hooks"])
    )
  rescue Psych::SyntaxError => e
    raise ParseError, "YAML parse error: #{e.message}"
  end

  private

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
    raise ParseError, "#{label}.name: #{name.inspect} is duplicated" if seen.include?(name)

    seen << name
    run = raw["run"].to_s.strip
    raise ParseError, "#{label}.run: is required" if run.empty?

    GradeStep.new(
      name: name,
      run: run,
      description: raw["description"].to_s.strip.presence,
      required: raw.key?("required") ? ActiveModel::Type::Boolean.new.cast(raw["required"]) : true,
      timeout_minutes: parse_timeout_minutes(raw.fetch("timeout_minutes", DEFAULT_GRADE_TIMEOUT_MINUTES), name)
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
end
