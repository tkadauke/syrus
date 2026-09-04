require "json"

class PrCommentClassifier
  DEFAULT_TIMEOUT_SECONDS = 20
  DEFAULT_MAX_TURNS = 1

  Result = Data.define(:actionable, :reason, :error) do
    def success? = error.nil?
  end

  def self.call(body:, user:, agent_provider:)
    new(body: body, user: user, agent_provider: agent_provider).call
  end

  def initialize(body:, user:, agent_provider:,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 max_turns: DEFAULT_MAX_TURNS)
    @body = body
    @user = user
    @agent_provider = agent_provider
    @timeout = timeout
    @max_turns = max_turns
  end

  def call
    judgment = Judgment.call(
      scope: "comment_classifier",
      prompt: Prompts::CommentClassifier.new(body: @body).to_s,
      user: @user,
      provider: @agent_provider,
      schema: %w[actionable],
      timeout: @timeout,
      max_turns: @max_turns
    )

    return classification_failure(judgment.error) if judgment.failed?

    Result.new(
      actionable: judgment.value["actionable"] == true,
      reason: judgment.value["reason"].to_s.strip.presence,
      error: nil
    )
  end

  private

  def classification_failure(reason)
    Rails.logger.warn("[PrCommentClassifier] classification error: #{reason}")
    failure(reason)
  end

  def failure(reason)
    Result.new(actionable: true, reason: nil, error: reason)
  end
end
