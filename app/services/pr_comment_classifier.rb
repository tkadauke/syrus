require "json"
require "tmpdir"

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
    prompt = Prompts::CommentClassifier.new(body: @body).to_s
    result = agent.run_once(
      prompt: prompt,
      log_sink: ->(*) { },
      timeout: @timeout,
      max_turns: @max_turns
    )

    return failure("timed out after #{@timeout}s") if result.timed_out
    return failure("agent error: #{result.outcome}") if result.is_error
    return failure("agent exited #{result.exit_status}") unless result.success?
    return failure("empty response") if result.final_text.blank?

    parse(result.final_text)
  rescue StandardError => e
    Rails.logger.warn("[PrCommentClassifier] classification error: #{e.class}: #{e.message}")
    failure("#{e.class}: #{e.message}")
  end

  private

  def parse(raw)
    text = raw.to_s.strip
    text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip
    parsed = JSON.parse(text)

    actionable = parsed["actionable"] == true
    reason = parsed["reason"].to_s.strip.presence

    Result.new(actionable: actionable, reason: reason, error: nil)
  rescue JSON::ParserError => e
    failure("invalid JSON: #{e.message[0..80]}")
  end

  def agent
    @agent ||= OneShotAgent.new(user: @user, provider: @agent_provider)
  end

  def failure(reason)
    Result.new(actionable: true, reason: nil, error: reason)
  end

  class OneShotAgent
    def initialize(user:, provider:)
      @user = user
      @provider = provider
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-comment-classifier") do |workspace_path|
        case @provider
        when "claude"
          ClaudeInvocation.new(
            workspace_path,
            prompt: prompt,
            oauth_token: @user.claude_oauth_token,
            log_sink: log_sink,
            runner: RunJob.agent_runner,
            timeout: timeout,
            max_turns: max_turns
          ).run
        when "codex"
          codex_home = File.join(WorkflowWorkspace.data_root, "agent_homes", "comment_classifier", @user.id.to_s, "codex")
          CodexAuth.with_refresh_lock(user: @user) do
            codex_auth = CodexAuth.new(user: @user, codex_home: codex_home)
            auth = codex_auth.prepare!
            begin
              CodexInvocation.new(
                workspace_path,
                prompt: prompt,
                api_key: auth.api_key,
                log_sink: log_sink,
                runner: RunJob.agent_runner,
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
