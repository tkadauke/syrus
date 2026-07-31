require "json"

class ChatTitleGenerator
  DEFAULT_TIMEOUT_SECONDS = 1.minute.to_i

  Result = Data.define(:title, :error) do
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

    result = invoke_agent

    return failure("timed out after #{@timeout}s") if result.timed_out
    return failure("agent reported #{result.outcome || 'error'}") if result.is_error
    return failure("agent exited #{result.exit_status}") unless result.success?
    return failure("empty response") if result.final_text.blank?

    parse(result.final_text)
  rescue StandardError => e
    failure("#{e.class}: #{e.message}")
  end

  private

  def invoke_agent
    OneShotAgent.new(user: @chat_session.user, provider: @chat_provider, runner: @runner).run_once(
      prompt: Prompts::ChatTitle.new(message: @message_text, repository: @chat_session.repository).to_s,
      log_sink: ->(*, **) { },
      timeout: @timeout,
      max_turns: 1
    )
  end

  def parse(raw)
    text = raw.strip
    text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip

    parsed = JSON.parse(text)
    title = parsed["title"].to_s.squish
    return failure("empty title") if title.blank?
    return failure("title too long (#{title.length} chars)") if title.length > ChatSession::TITLE_MAX_LENGTH

    Result.new(title: title, error: nil)
  rescue JSON::ParserError => e
    failure("invalid JSON: #{e.message[0..120]}")
  end

  def failure(reason)
    Result.new(title: nil, error: reason)
  end

  class OneShotAgent
    def initialize(user:, provider:, runner:)
      @user = user
      @provider = provider
      @runner = runner
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      AgentProviders.run_one_shot(
        provider: @provider,
        user: @user,
        runner: @runner,
        scope: "chat-title",
        prompt: prompt,
        log_sink: log_sink,
        timeout: timeout,
        max_turns: max_turns
      )
    end
  end
end
