class AutoRetryFailureClassifier
  Result = Data.define(:classification, :retryable, :reason) do
    def retryable? = retryable
  end

  RETRYABLE_AGENT_OUTCOMES = {
    "worker_died" => "worker process died",
    "error_during_execution" => "provider reported a transient execution error",
    "server_error" => "provider reported a server-side transient error",
    "turn_failed" => "provider turn failed",
    "error" => "provider reported a generic transient error",
    "mcp_sidecar_failed" => "MCP sidecar failed to start or connect"
  }.freeze

  NON_RETRYABLE_AGENT_OUTCOMES = {
    ProviderAuthFailure::OUTCOME => "provider authentication token expired",
    ProviderUsageLimit::OUTCOME => "provider usage limit or model quota exhausted",
    "error_max_turns" => "agent exhausted max turns",
    "git_state_corrupt" => "agent corrupted git state",
    "operator_cancelled" => "operator cancelled the run",
    "success" => "run succeeded"
  }.freeze

  RETRYABLE_ERROR_CLASSES = %w[
    ActiveRecord::ConnectionNotEstablished
    ActiveRecord::ConnectionTimeoutError
    Timeout::Error
    Net::OpenTimeout
    Net::ReadTimeout
    Faraday::TimeoutError
    Faraday::ConnectionFailed
    Octokit::BadGateway
    Octokit::InternalServerError
    Octokit::ServiceUnavailable
    Octokit::TooManyRequests
    Octokit::ServerError
    Steps::Base::AgentGaveUpWaiting
  ].freeze

  # Fallback for failures with no declared Problem -- including every row
  # written before steps carried one. Prefer declaring a Problem at the raise
  # site over adding a pattern here; a pattern cannot be checked against the
  # code it describes, which is how the merge-train entries below drifted out
  # of sync with the messages those steps actually raise.
  NON_RETRYABLE_MESSAGE_PATTERNS = [
    /agent produced no changes/i,
    /agent didn't call submit_summary/i,
    /agent's branch has no common ancestor/i,
    /git_state_corrupt/i,
    /non-retryable workspace setup failure/i,
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
    /merge_train_agent_rebase: .* rebuild required/i,
    /merge_train: integration PR has merge conflicts .*operator intervention required/i
  ].freeze

  RETRYABLE_MESSAGE_PATTERNS = [
    /agent timed out/i,
    /timed out/i,
    /execution expired/i,
    /worker died/i,
    /connection reset/i,
    /temporar(?:y|ily)/i,
    /rate[_ -]?limit/i,
    /too many requests/i,
    /too many connections/i,
    /could not obtain a connection/i,
    /ConnectionNotEstablished/i,
    /ConnectionTimeoutError/i,
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
    if run.run_failure_classification&.classification == "agent_resume_unavailable"
      return retryable("agent_resume_unavailable", run.run_failure_classification.reason)
    end
    if run.run_failure_classification&.classification == ProviderAuthFailure::CLASSIFICATION
      return non_retryable(ProviderAuthFailure::CLASSIFICATION, run.run_failure_classification.reason.presence || "provider authentication token expired")
    end
    if provider_auth_failure?(run)
      return non_retryable(ProviderAuthFailure::CLASSIFICATION, "provider authentication token expired")
    end

    outcome = run.agent_outcome.to_s.presence
    return non_retryable(outcome, NON_RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if NON_RETRYABLE_AGENT_OUTCOMES.key?(outcome)
    return retryable(outcome, RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if RETRYABLE_AGENT_OUTCOMES.key?(outcome)

    diagnostic = run.run_diagnostic
    if diagnostic
      # A step that declared its Problem already answered this question:
      # Problem::Kind carries `retryable` per code. Consulted ahead of the
      # message patterns below, which are a fourth private copy of the same
      # judgement and were missing most of the merge-train failures they name.
      if (declared = declared_problem(diagnostic))
        return declared.retryable? ? retryable(declared.code, "the step reported a retryable problem") \
                                   : non_retryable(declared.code, "the step reported a non-retryable problem")
      end

      message = [ diagnostic.error_message, diagnostic.error_class ].compact.join(" ")
      return non_retryable("non_retryable_failure", "known user/code/config failure") if self.class.non_retryable_message?(message)
      return retryable(diagnostic.error_class, "retryable exception class") if retryable_error_class?(diagnostic.error_class)
      return retryable("transient_process_failure", "retryable diagnostic message") if RETRYABLE_MESSAGE_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    non_retryable(outcome || diagnostic&.error_class || "unknown", "failure is not retryable")
  end

  private

  attr_reader :workflow

  # Resolved through the registry rather than trusted verbatim, so a code that
  # no longer exists falls back to the patterns instead of raising.
  def declared_problem(diagnostic)
    code = diagnostic.problem_code
    return nil if code.blank?

    Problem.resolve(code)
  end

  def latest_failed_run
    workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
  end

  def retryable_error_class?(error_class)
    RETRYABLE_ERROR_CLASSES.include?(error_class.to_s) ||
      error_class.to_s.end_with?("TimeoutError", "Timeout")
  end

  def provider_auth_failure?(run)
    return false if run.agent_provider.blank?

    diagnostic = run.run_diagnostic
    text = [
      run.agent_outcome,
      run.agent_summary,
      run.agent_pr_title,
      run.agent_pr_body,
      diagnostic&.error_class,
      diagnostic&.error_message,
      diagnostic&.error_backtrace,
      recent_log_chunks(run)
    ].flatten.compact.join("\n")
    ProviderAuthFailure.detect?(text)
  end

  def recent_log_chunks(run)
    run.job_logs.order(sequence: :desc).limit(RunFailureClassifier::RECENT_LOG_LIMIT).pluck(:chunk)
  end

  def retryable(classification, reason)
    Result.new(classification: classification, retryable: true, reason: reason)
  end

  def non_retryable(classification, reason)
    Result.new(classification: classification, retryable: false, reason: reason)
  end
end
