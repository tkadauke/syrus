require "json"
require "tmpdir"

class DirectJobTitleGenerator
  FALLBACK_TITLE = "Direct job"
  DEFAULT_TIMEOUT_SECONDS = 30
  MAX_TITLE_BYTES = 100

  Result = Data.define(:title, :error) do
    def success? = error.nil?
  end

  def self.call(prompt, user:, repository:, agent_provider:, runner: RunJob.agent_runner)
    generated = generate(
      prompt,
      user: user,
      repository: repository,
      agent_provider: agent_provider,
      runner: runner
    )
    generated.success? ? generated.title : FALLBACK_TITLE
  end

  def self.generate(prompt, user:, repository:, agent_provider:, runner: RunJob.agent_runner)
    new(
      prompt,
      user: user,
      repository: repository,
      agent_provider: agent_provider,
      runner: runner
    ).generate
  end

  def initialize(prompt, user:, repository:, agent_provider:, runner: RunJob.agent_runner,
                 timeout: DEFAULT_TIMEOUT_SECONDS)
    @prompt = prompt.to_s
    @user = user
    @repository = repository
    @agent_provider = agent_provider.to_s
    @runner = runner
    @timeout = timeout
  end

  def call
    generated = generate
    generated.success? ? generated.title : FALLBACK_TITLE
  end

  attr_reader :prompt, :user, :repository, :agent_provider, :runner, :timeout

  def generate
    return failure("agent provider is not configured") unless user.agent_provider_configured?(agent_provider)

    parse(invoke_agent)
  end

  private

  def invoke_agent
    Judgment.call(
      scope: "direct-job-title",
      prompt: Prompts::DirectJobTitle.new(prompt: prompt, repository: repository).to_s,
      user: user,
      provider: agent_provider,
      runner: runner,
      schema: %w[title],
      timeout: timeout,
      max_turns: 1
    )
  end

  def parse(judgment)
    return failure(judgment.error) if judgment.failed?

    title = strip_wrapping_marks(judgment.value["title"].to_s.squish)
    return failure("empty title") if title.blank?

    Result.new(title: truncate(title), error: nil)
  end

  def failure(reason)
    Result.new(title: nil, error: reason)
  end

  def truncate(text)
    return text if text.bytesize <= MAX_TITLE_BYTES

    text.safe_byteslice(0, MAX_TITLE_BYTES).strip
  end

  def strip_wrapping_marks(text)
    result = text.to_s.strip
    loop do
      stripped = result
                 .sub(/\A[`'"]+/, "")
                 .sub(/[`'"]+\z/, "")
                 .strip
      return stripped if stripped == result

      result = stripped
    end
  end
end
