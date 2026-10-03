require "json"

class ChatTitleGenerator
  DEFAULT_TIMEOUT_SECONDS = 1.minute.to_i

  Result = Data.define(:title, :error, :problem_code) do
    def success? = error.nil?
  end

  def initialize(chat_session:, message_text:, chat_provider:, runner: nil, timeout: DEFAULT_TIMEOUT_SECONDS)
    @chat_session = chat_session
    @message_text = message_text
    @chat_provider = chat_provider.to_s
    @runner = runner
    @timeout = timeout
  end

  def call
    return failure("chat provider is not configured") unless @chat_session.user.chat_provider_configured?(@chat_provider)

    parse(invoke_agent)
  end

  private

  def invoke_agent
    Judgment.call(
      scope: "chat-title",
      prompt: Prompts::ChatTitle.new(message: @message_text, repository: @chat_session.repository).to_s,
      user: @chat_session.user,
      provider: @chat_provider,
      runner: @runner,
      schema: %w[title],
      timeout: @timeout,
      max_turns: 1
    )
  end

  def parse(judgment)
    return failure(judgment.error, problem_code: judgment.problem&.code) if judgment.failed?

    title = judgment.value["title"].to_s.squish
    return failure("empty title") if title.blank?
    return failure("title too long (#{title.length} chars)") if title.length > ChatSession::TITLE_MAX_LENGTH

    Result.new(title: title, error: nil, problem_code: nil)
  end

  def failure(reason, problem_code: nil)
    Result.new(title: nil, error: reason, problem_code: problem_code)
  end
end
