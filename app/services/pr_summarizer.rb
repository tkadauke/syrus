require "json"

# Single-shot agent call that authors a PR title + body from the issue
# and the agent's diff. The provider invocation is pinned to one turn.
class PrSummarizer
  DEFAULT_TIMEOUT_SECONDS = 2.minutes.to_i

  Result = Data.define(:title, :body, :error) do
    def success? = error.nil?
  end

  def initialize(issue:, diff:, agent:,
                 log_sink: ->(*, **) { },
                 timeout: DEFAULT_TIMEOUT_SECONDS)
    @issue = issue
    @diff = diff
    @agent = agent
    @log_sink = log_sink
    @timeout = timeout
  end

  def call
    prompt = Prompts::PullRequestSummary.new(issue: @issue, diff: @diff).to_s

    result = invoke_agent(prompt)

    return failure("timed out after #{@timeout}s") if result.timed_out
    return failure("agent reported #{result.outcome || 'error'}") if result.is_error
    return failure("agent exited #{result.exit_status}") unless result.success?
    return failure("empty response") if result.final_text.blank?

    parse(result.final_text)
  rescue StandardError => e
    failure("#{e.class}: #{e.message}")
  end

  private

  def invoke_agent(prompt)
    @agent.run_once(prompt: prompt,
                    log_sink: @log_sink,
                    timeout: @timeout,
                    max_turns: 1)
  end

  def parse(raw)
    text = raw.strip
    # Strip surrounding ```json … ``` fences the agent sometimes adds
    # despite the explicit instruction not to.
    text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip

    parsed = JSON.parse(text)
    title = parsed["title"].to_s.strip
    body = parsed["body"].to_s.strip

    return failure("empty title") if title.empty?
    return failure("title too long (#{title.length} chars)") if title.length > 120

    Result.new(title: title, body: body, error: nil)
  rescue JSON::ParserError => e
    failure("invalid JSON: #{e.message[0..120]}")
  end

  def failure(reason)
    Result.new(title: nil, body: nil, error: reason)
  end
end
