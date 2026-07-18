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

  Grader = Data.define(:name, :command, :description, :required, :timeout_minutes, :when_files_changed)
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

    graders = grade.steps.map { |step| grader_for(step) }
    note = graders.empty? ? "no valid graders configured" : nil
    Result.new(graders: graders, source: ".syrus.yml", note: note, max_iterations: grade.max_iterations)
  rescue SyrusYml::ParseError => e
    empty_result(source: ".syrus.yml", note: e.message)
  end

  private

  def config_present?
    @path.join(CONFIG_FILE).exist?
  end

  def grader_for(step)
    Grader.new(
      name: step.name,
      command: step.run,
      description: step.description,
      required: step.required,
      timeout_minutes: step.timeout_minutes,
      when_files_changed: step.when_files_changed
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
