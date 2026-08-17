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

  # Two commands, not three. `run:` is the everyday command and is already
  # parallel; `ci:` layers the isolated serial :ci_only pass on top of it for
  # ci_failure and main-branch graders. The old `fast:` variant selected a
  # parallel command while `run:` stayed serial, which meant the first grader
  # pass of every workflow — the common case — ran single-threaded. A
  # `.syrus.yml` that still declares `fast:` falls back here to `run:`.
  Grader = Data.define(:name, :command, :ci_command, :description, :required, :timeout_minutes, :when_files_changed, :junit_output, :metadata) do
    def command_for(variant:)
      variant.to_sym == :ci ? ci_command.presence || command : command
    end
  end
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
      ci_command: step.ci,
      description: step.description,
      required: step.required,
      timeout_minutes: step.timeout_minutes,
      when_files_changed: step.when_files_changed,
      junit_output: step.junit_output,
      metadata: {}
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
