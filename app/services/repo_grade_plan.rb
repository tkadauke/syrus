# Resolves Syrus-native CI graders declared in `.syrus.yml`.
# Supports both:
#
#   grade:
#     steps:
#       - name: tests
#         run: bin/rspec
#
# and the shorthand:
#
#   grade:
#     - name: tests
#       run: bin/rspec
class RepoGradePlan
  CONFIG_FILE = ".syrus.yml".freeze
  NAME_PATTERN = SyrusYml::GRADE_NAME_PATTERN

  # A grader is a single immutable command selected by phase. Legacy `.syrus.yml`
  # files may still declare `ci:` beside `run:`; resolve expands that into a
  # separate `<name>-ci` grader whose only phase is `ci`.
  Grader = Data.define(:name, :command, :phases, :description, :required, :timeout_minutes, :when_files_changed, :junit_output, :failures, :metadata)
  Result = Data.define(:graders, :source, :note, :max_iterations)

  def self.for(workspace_path)
    new(workspace_path).resolve
  end

  def initialize(workspace_path)
    @path = Pathname.new(workspace_path)
  end

  def resolve
    return empty_result(source: "none", note: "no .syrus.yml") unless config_present?

    config = SyrusYml.load_repo(@path)
    grade = config.grade

    return empty_result(source: ".syrus.yml", note: "no graders configured") unless grade

    graders = expand_graders(grade.steps)
    note = graders.empty? ? "no valid graders configured" : nil
    Result.new(graders: graders, source: ".syrus.yml", note: note, max_iterations: grade.max_iterations)
  rescue SyrusYml::ParseError => e
    empty_result(source: ".syrus.yml", note: e.message)
  end

  private

  def config_present?
    @path.join(CONFIG_FILE).exist?
  end

  def expand_graders(steps)
    graders = steps.flat_map { |step| graders_for(step) }
    names = graders.map(&:name)
    duplicate = names.find { |name| names.count(name) > 1 }
    raise SyrusYml::ParseError, "grade step #{duplicate.inspect}: legacy ci expansion conflicts with another grader name" if duplicate

    graders
  end

  def graders_for(step)
    primary_phases = step.ci.present? ? step.phases - [ "ci" ] : step.phases
    graders = []
    graders << grader_for(step, name: step.name, command: step.run, phases: primary_phases) if primary_phases.any?
    if step.ci.present?
      graders << grader_for(step, name: "#{step.name}-ci", command: step.ci, phases: [ "ci" ], legacy_ci: true)
    end
    graders
  end

  def grader_for(step, name:, command:, phases:, legacy_ci: false)
    Grader.new(
      name: name,
      command: command,
      phases: phases,
      description: step.description,
      required: step.required,
      timeout_minutes: step.timeout_minutes,
      when_files_changed: step.when_files_changed,
      junit_output: step.junit_output,
      failures: step.failures,
      metadata: legacy_ci ? { "legacy_ci_command" => true, "legacy_source_grader" => step.name } : {}
    )
  end

  def empty_result(source:, note:)
    Result.new(
      graders: [],
      source: source,
      note: note,
      max_iterations: AppSetting.grade_max_iterations
    )
  end
end
