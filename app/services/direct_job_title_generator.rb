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

    result = invoke_agent
    return failure("timed out after #{timeout}s") if result.timed_out
    return failure("agent reported #{result.outcome || 'error'}") if result.is_error
    return failure("agent exited #{result.exit_status}") unless result.success?
    return failure("empty response") if result.final_text.blank?

    parse(result.final_text)
  rescue StandardError => e
    failure("#{e.class}: #{e.message}")
  end

  private

  def invoke_agent
    OneShotAgent.new(user: user, provider: agent_provider, runner: runner).run_once(
      prompt: Prompts::DirectJobTitle.new(prompt: prompt, repository: repository).to_s,
      log_sink: ->(*, **) { },
      timeout: timeout,
      max_turns: 1
    )
  end

  def parse(raw)
    text = raw.to_s.strip
    text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip

    parsed = JSON.parse(text)
    title = strip_wrapping_marks(parsed["title"].to_s.squish)
    return failure("empty title") if title.blank?

    Result.new(title: truncate(title), error: nil)
  rescue JSON::ParserError => e
    failure("invalid JSON: #{e.message[0..120]}")
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

  class OneShotAgent
    def initialize(user:, provider:, runner:)
      @user = user
      @provider = provider
      @runner = runner
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-direct-job-title") do |workspace_path|
        case @provider
        when "claude"
          ClaudeInvocation.new(
            workspace_path,
            prompt: prompt,
            oauth_token: @user.claude_oauth_token,
            log_sink: log_sink,
            runner: @runner,
            timeout: timeout,
            max_turns: max_turns
          ).run
        when "codex"
          codex_home = File.join(
            WorkflowWorkspace.data_root,
            "agent_homes",
            "direct_job_title",
            @user.id.to_s,
            "codex"
          )
          CodexAuth.with_refresh_lock(user: @user) do
            codex_auth = CodexAuth.new(user: @user, codex_home: codex_home)
            auth = codex_auth.prepare!
            begin
              CodexInvocation.new(
                workspace_path,
                prompt: prompt,
                api_key: auth.api_key,
                log_sink: log_sink,
                runner: @runner,
                timeout: timeout,
                codex_home: codex_home
              ).run
            ensure
              codex_auth.persist_updated_auth_json
            end
          end
        else
          raise AgentProviders::ConfigurationError, "Unknown agent provider: #{@provider.inspect}"
        end
      end
    end
  end
end
