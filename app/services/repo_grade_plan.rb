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
  #
  # `display_name` is the resolved operator-facing label (see
  # `SyrusYml::GradeStep`); nil means "no explicit or type-generated label --
  # fall back to a humanized `name`," which downstream display code (the
  # workflow serializer) already handles.
  Grader = Data.define(:name, :display_name, :command, :phases, :description, :required, :timeout_minutes, :when_files_changed, :junit_output, :failures, :base_retry, :deps, :metadata) do
    def initialize(display_name: nil, **rest)
      super(display_name: display_name, **rest)
    end
  end
  Result = Data.define(:graders, :source, :note, :max_iterations, :rerun_only_failed) do
    def rerun_only_failed?
      !!rerun_only_failed
    end
  end

  def self.for(workspace_path, project_path: nil)
    new(workspace_path, project_path: project_path).resolve
  end

  def initialize(workspace_path, project_path: nil)
    @path = Pathname.new(workspace_path)
    @project_path = project_path.to_s.strip.presence
  end

  def resolve
    return empty_result(source: "none", note: "no .syrus.yml") unless config_present?

    config = SyrusYml.load_repo(@path, project_path: @project_path)
    grade = config.grade

    return empty_result(source: ".syrus.yml", note: "no graders configured") unless grade

    graders = expand_graders(grade.steps)
    note = graders.empty? ? "no valid graders configured" : nil
    Result.new(graders: graders, source: ".syrus.yml", note: note, max_iterations: grade.max_iterations, rerun_only_failed: grade.rerun_only_failed)
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
    metadata = step.metadata.to_h
    metadata = metadata.merge("legacy_ci_command" => true, "legacy_source_grader" => step.name) if legacy_ci

    Grader.new(
      name: name,
      display_name: display_name_for(step, legacy_ci: legacy_ci),
      command: command,
      phases: phases,
      description: step.description,
      required: step.required,
      timeout_minutes: step.timeout_minutes,
      when_files_changed: step.when_files_changed,
      junit_output: step.junit_output,
      failures: step.failures,
      base_retry: step.base_retry,
      deps: step.deps,
      metadata: metadata
    )
  end

  # The legacy `<name>-ci` expansion shares its source step's explicit or
  # type-generated `display_name` (when present) but needs its own mode
  # suffix so the two graders don't read identically in the UI.
  def display_name_for(step, legacy_ci:)
    base = step.display_name
    return nil unless base

    legacy_ci ? "#{base} (CI)" : base
  end

  def empty_result(source:, note:)
    Result.new(
      graders: [],
      source: source,
      note: note,
      max_iterations: AppSetting.grade_max_iterations,
      rerun_only_failed: false
    )
  end
end
