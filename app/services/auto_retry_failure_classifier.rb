class AutoRetryFailureClassifier
  Result = Data.define(:classification, :retryable, :reason) do
    def retryable? = retryable
  end

  RETRYABLE_AGENT_OUTCOMES = {
    "worker_died" => "worker process died",
    "error_during_execution" => "provider reported a transient execution error",
    "turn_failed" => "provider turn failed",
    "error" => "provider reported a generic transient error",
    "mcp_sidecar_failed" => "MCP sidecar failed to start or connect"
  }.freeze

  NON_RETRYABLE_AGENT_OUTCOMES = {
    ProviderUsageLimit::OUTCOME => "provider usage limit or model quota exhausted",
    "error_max_turns" => "agent exhausted max turns",
    "git_state_corrupt" => "agent corrupted git state",
    "operator_cancelled" => "operator cancelled the run",
    "success" => "run succeeded"
  }.freeze

  RETRYABLE_ERROR_CLASSES = %w[
    Timeout::Error
    Net::OpenTimeout
    Net::ReadTimeout
    Faraday::TimeoutError
    Faraday::ConnectionFailed
    Octokit::TooManyRequests
    Octokit::ServerError
  ].freeze

  NON_RETRYABLE_MESSAGE_PATTERNS = [
    /agent produced no changes/i,
    /agent didn't call submit_summary/i,
    /agent's branch has no common ancestor/i,
    /git_state_corrupt/i,
    /prepare command failed/i,
    /PR branch changed before Syrus could push/i,
    /branch diverged/i,
    /has no completed implement (?:session|run)/i,
    /required graders? failed/i,
    /required grader failed/i,
    /rebase cap reached/i,
    /This branch can't be rebased/i,
    /merge_train: rebase for .* was not completed/i,
    /merge_train: integrating .* left a dirty worktree/i,
    /merge_train: .* was not rebased onto the integration branch/i,
    /merge_train: base moved .* rebuild required/i,
    /merge_train: missing built base SHA; rebuild required/i,
    /merge_train_reconcile: built integration branch .* rebuild required/i,
    /merge_train: integration PR has merge conflicts .*operator intervention required/i
  ].freeze

  RETRYABLE_MESSAGE_PATTERNS = [
    /agent timed out/i,
    /timed out/i,
    /execution expired/i,
    /worker died/i,
    /connection reset/i,
    /temporar(?:y|ily)/i,
    /rate limit/i,
    /too many requests/i,
    /5\d\d/
  ].freeze

  def self.call(...) = new(...).call

  def self.non_retryable_message?(message)
    NON_RETRYABLE_MESSAGE_PATTERNS.any? { |pattern| message.to_s.match?(pattern) }
  end

  def initialize(workflow:)
    @workflow = workflow
  end

  def call
    run = latest_failed_run
    return non_retryable("unknown", "no failed run") unless run

    outcome = run.agent_outcome.to_s.presence
    return non_retryable(outcome, NON_RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if NON_RETRYABLE_AGENT_OUTCOMES.key?(outcome)
    return retryable(outcome, RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if RETRYABLE_AGENT_OUTCOMES.key?(outcome)

    diagnostic = run.run_diagnostic
    if diagnostic
      message = [ diagnostic.error_message, diagnostic.error_class ].compact.join(" ")
      return non_retryable("non_retryable_failure", "known user/code/config failure") if self.class.non_retryable_message?(message)
      return retryable(diagnostic.error_class, "retryable exception class") if retryable_error_class?(diagnostic.error_class)
      return retryable("transient_process_failure", "retryable diagnostic message") if RETRYABLE_MESSAGE_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    non_retryable(outcome || diagnostic&.error_class || "unknown", "failure is not retryable")
  end

  private

  attr_reader :workflow

  def latest_failed_run
    workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
  end

  def retryable_error_class?(error_class)
    RETRYABLE_ERROR_CLASSES.include?(error_class.to_s) ||
      error_class.to_s.end_with?("TimeoutError", "Timeout")
  end

  def retryable(classification, reason)
    Result.new(classification: classification, retryable: true, reason: reason)
  end

  def non_retryable(classification, reason)
    Result.new(classification: classification, retryable: false, reason: reason)
  end
end
