require "yaml"

class OperatorChatPolicy
  CONFIG_FILE = ".syrus.yml".freeze
  DEFAULT_MAX_QUESTIONS = 5

  Result = Data.define(:allowed, :reason)

  def self.evaluate(run)
    new(run).evaluate
  end

  def self.max_questions_for(workflow)
    new(nil, workflow: workflow).max_questions
  end

  def initialize(run, workflow: nil)
    @run = run
    @workflow = workflow || run.workflow
    @job = @workflow.job
  end

  def evaluate
    if @job.operator_chat_disabled?
      return Result.new(
        allowed: false,
        reason: "`#{Job::OPERATOR_CHAT_OPT_OUT_LABEL}` label disables operator chat for this Job. Mark this run failed with category `needs_clarification` instead."
      )
    end

    cap = max_questions
    asked = @workflow.operator_questions.count
    if asked >= cap
      return Result.new(
        allowed: false,
        reason: "ask_operator question cap hit for this Workflow (#{asked}/#{cap}). Mark this run failed with category `needs_clarification` instead."
      )
    end

    Result.new(allowed: true, reason: nil)
  end

  def max_questions
    raw = config.fetch("max_operator_questions", DEFAULT_MAX_QUESTIONS)
    value = Integer(raw)
    value >= 0 ? value : DEFAULT_MAX_QUESTIONS
  rescue ArgumentError, TypeError
    DEFAULT_MAX_QUESTIONS
  end

  private

  def config
    path = WorkflowWorkspace.path_for(@workflow).join(CONFIG_FILE)
    return {} unless path.exist?

    yaml = YAML.safe_load(path.read)
    yaml.is_a?(Hash) ? yaml : {}
  rescue Psych::SyntaxError
    {}
  end
end
