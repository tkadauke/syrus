# One bounded agent turn that answers a question (workflow-engine-v3 B4).
#
# Four services grew their own `OneShotAgent` -- ingestion classification, PR
# comment classification, chat titles, direct job titles -- identical except
# for a scope string. Each also re-implemented fenced-JSON extraction, and none
# of them had a cost ceiling.
#
# A Judgment is a Run with no workspace: a prompt, a declared output schema,
# and two guardrails the plan requires from the day the primitive lands --
# a cost ceiling and a timeout that reports as a Problem rather than as a bare
# exception. Anything wanting an agent's opinion (rather than an agent's edit)
# goes through here.
class Judgment
  # Every failure is one of these, in the shared vocabulary where one exists.
  Result = Data.define(:value, :raw_text, :problem, :cost_usd) do
    def ok? = problem.nil?
    def failed? = !ok?
    def error = problem&.evidence&.dig(:reason)
  end

  DEFAULT_TIMEOUT_SECONDS = 60
  DEFAULT_MAX_TURNS = 1

  # A judgment that costs more than the decision is worth is a bug, not a
  # result. Enforced after the fact -- the provider bills what it bills -- but
  # a breach fails the judgment rather than silently returning an answer
  # nobody budgeted for.
  DEFAULT_COST_CEILING_USD = 0.50

  def self.call(...) = new(...).call

  # `schema` names the keys the answer must carry. It is deliberately small:
  # the point is that a judgment declares its output shape at all, not that
  # Syrus grows a JSON-schema validator.
  def initialize(scope:, prompt:, user:, provider:, schema: [], runner: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS, max_turns: DEFAULT_MAX_TURNS,
                 cost_ceiling_usd: DEFAULT_COST_CEILING_USD, log_sink: nil)
    @scope = scope
    @prompt = prompt
    @user = user
    @provider = provider
    @schema = Array(schema).map(&:to_s)
    @runner = runner || RunJob.agent_runner
    @timeout = timeout
    @max_turns = max_turns
    @cost_ceiling_usd = cost_ceiling_usd
    @log_sink = log_sink || ->(*, **) { }
  end

  def call
    result = invoke
    cost = extract_cost(result)

    provider_problem(result, cost: cost) || over_ceiling(cost) || parse(result.final_text, cost: cost)
  rescue Timeout::Error, Errno::ETIMEDOUT => e
    # The plan's "timeout remediation from the day the primitive lands": a
    # timed-out judgment is a known Problem with a retry default, not an
    # exception the caller has to recognize.
    failure(Problem[:timeout, evidence: { scope: @scope, reason: e.message, after_seconds: @timeout }])
  rescue StandardError => e
    failure(Problem[:application_error, evidence: { scope: @scope, reason: "#{e.class}: #{e.message}" }])
  end

  private

  def invoke
    AgentProviders.run_one_shot(
      provider: @provider,
      user: @user,
      runner: @runner,
      scope: @scope,
      prompt: @prompt,
      log_sink: @log_sink,
      timeout: @timeout,
      max_turns: @max_turns
    )
  end

  # The provider-level outcomes every copy of this checked by hand, stated
  # once and in the shared vocabulary.
  def provider_problem(result, cost:)
    if result.respond_to?(:timed_out) && result.timed_out
      return failure(Problem[:timeout, evidence: { scope: @scope, reason: "timed out after #{@timeout}s", after_seconds: @timeout }], cost: cost)
    end
    if result.respond_to?(:is_error) && result.is_error
      return failure(Problem[:application_error, evidence: { scope: @scope, reason: "agent reported #{result.try(:outcome) || 'error'}" }], cost: cost)
    end
    if result.respond_to?(:success?) && !result.success?
      return failure(Problem[:application_error, evidence: { scope: @scope, reason: "agent exited #{result.try(:exit_status)}" }], cost: cost)
    end

    nil
  end

  def over_ceiling(cost)
    return nil if @cost_ceiling_usd.nil? || cost.nil?
    return nil if cost <= @cost_ceiling_usd

    failure(
      Problem[:application_error, evidence: {
        scope: @scope, reason: "judgment cost #{cost} exceeded ceiling #{@cost_ceiling_usd}"
      }],
      cost: cost
    )
  end

  # Agents fence their JSON about half the time; every copy of this re-derived
  # the same strip.
  def parse(raw, cost:)
    text = raw.to_s.strip.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip
    return failure(Problem[:missing_required_tool_call, evidence: { scope: @scope, reason: "empty response" }], cost: cost) if text.blank?

    value = JSON.parse(text)
    missing = @schema.reject { |key| value.is_a?(Hash) && value.key?(key) }
    if missing.any?
      return failure(
        Problem[:missing_required_tool_call, evidence: { scope: @scope, reason: "missing keys: #{missing.join(', ')}" }],
        raw_text: text, cost: cost
      )
    end

    Result.new(value: value, raw_text: text, problem: nil, cost_usd: cost)
  rescue JSON::ParserError => e
    failure(
      Problem[:validation_or_user_error, evidence: { scope: @scope, reason: "invalid JSON: #{e.message[0..120]}" }],
      raw_text: text, cost: cost
    )
  end

  def extract_cost(result)
    return nil unless result.respond_to?(:cost_usd)

    result.cost_usd
  end

  def failure(problem, raw_text: nil, cost: nil)
    Result.new(value: nil, raw_text: raw_text, problem: problem, cost_usd: cost)
  end
end
