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
    ProviderModelUnsupported::OUTCOME => "provider refused the requested model",
    ProviderUsageLimit::OUTCOME => "provider usage limit or model quota exhausted",
    "error_max_turns" => "agent exhausted max turns",
    "git_state_corrupt" => "agent corrupted git state",
    "muse_rules_context_too_large" => "Muse workspace rules file exceeds the provider startup context limit",
    "operator_cancelled" => "operator cancelled the run",
    "success" => "run succeeded"
  }.freeze

  RETRYABLE_ERROR_CLASSES = %w[
    ActiveRecord::ConnectionNotEstablished
    ActiveRecord::ConnectionTimeoutError
    ActiveModel::MissingAttributeError
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
  #
  # Keep these patterns to legacy rows and external tool/provider prose only.
  # New Syrus-owned operational raise sites should use `fail_with!` or an
  # exception class `problem_code` so the diagnostic carries the decision.
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

  def self.retryable_exception?(exception)
    retryable_error_class?(exception.class.name) ||
      retryable_message?("#{exception.class}: #{exception.message}")
  end

  def self.retryable_error_class?(error_class)
    RETRYABLE_ERROR_CLASSES.include?(error_class.to_s) ||
      error_class.to_s.end_with?("TimeoutError", "Timeout")
  end

  def self.retryable_message?(message)
    text = message.to_s
    !non_retryable_message?(text) &&
      RETRYABLE_MESSAGE_PATTERNS.any? { |pattern| text.match?(pattern) }
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
      return provider_auth_result(run, run.run_failure_classification.reason)
    end
    if run.run_failure_classification&.classification == ProviderModelUnsupported::CLASSIFICATION
      return non_retryable(
        ProviderModelUnsupported::CLASSIFICATION,
        run.run_failure_classification.reason.presence || "provider refused the requested model"
      )
    end
    if authoritative_run_failure_classification?(run.run_failure_classification)
      classification = run.run_failure_classification
      reason = classification.reason.presence || "run failure classifier marked #{classification.classification}"
      return classification.retryable? ? retryable(classification.classification, reason) : non_retryable(classification.classification, reason)
    end
    return provider_auth_result(run, nil) if provider_auth_failure?(run)

    diagnostic = run.run_diagnostic
    # New Syrus-owned operational failures declare a Problem on the captured
    # diagnostic. Read that before agent-outcome compatibility shims so outcome
    # names such as `mcp_sidecar_failed` do not mask the canonical Problem code.
    if diagnostic && (declared = declared_problem(diagnostic))
      return declared.retryable? ? retryable(declared.code, "the step reported a retryable problem") \
                                 : non_retryable(declared.code, "the step reported a non-retryable problem")
    end

    outcome = run.agent_outcome.to_s.presence
    return non_retryable(outcome, NON_RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if NON_RETRYABLE_AGENT_OUTCOMES.key?(outcome)
    return retryable(outcome, RETRYABLE_AGENT_OUTCOMES.fetch(outcome)) if RETRYABLE_AGENT_OUTCOMES.key?(outcome)

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

  AUTHORITATIVE_RUN_FAILURE_CLASSIFICATIONS = %w[
    disk_full
    grader_failure
    worker_died
    worker_died_under_resource_pressure
  ].freeze

  def authoritative_run_failure_classification?(classification)
    classification&.classification.in?(AUTHORITATIVE_RUN_FAILURE_CLASSIFICATIONS)
  end

  # Resolved through the registry rather than trusted verbatim, so a code that
  # no longer exists falls back to the patterns instead of raising.
  def declared_problem(diagnostic)
    code = diagnostic.problem_code
    return nil if code.blank?

    Problem.resolve(code)
  end

  # One decision for an expired token however it was detected -- a persisted
  # classification or the provider's own diagnostics -- so the two cannot
  # disagree about whether it is worth retrying.
  def provider_auth_result(run, reason)
    reason = reason.presence || "provider authentication token expired"
    return non_retryable(ProviderAuthFailure::CLASSIFICATION, reason) unless provider_failover_available?(run)

    retryable(ProviderAuthFailure::CLASSIFICATION, "#{reason}; another provider is available for retry")
  end

  # An expired token says nothing about the work -- only about where it was
  # sent. A token can expire between admission and use, as one did in
  # production between 09:03 and 09:28, so no availability check at admission
  # can prevent it; the run that discovers the expiry is the one that pays. It
  # is worth retrying exactly when there is somewhere else to send it, and the
  # auth-error evidence the failure writes steers routing away from the
  # expired provider.
  #
  # On a single-provider instance the retry would land on the same refusal, so
  # escalation stays the right answer there. Unlike AutoRetryJob's circuit
  # check this does not require a retry-specific routing rule: the question is
  # whether another candidate exists at all, not whether one was configured
  # for retries in particular.
  def provider_failover_available?(run)
    job = run.job
    return false unless job

    ProviderRouting::Resolver.call(job: job, task_key: "retry").any? do |candidate|
      provider = candidate.provider.to_s
      next false if provider.blank? || provider == run.agent_provider.to_s

      provider_usable?(job.user, provider)
    end
  rescue StandardError
    false
  end

  # "Configured" is not enough: retrying onto a provider whose own credentials
  # are expired spends a retry to reach the same refusal. Availability reports
  # `open` for a provider routing has to skip.
  def provider_usable?(user, provider)
    App::ProviderAvailability.for_user(user, provider)[:open] != true
  rescue StandardError
    true
  end

  def latest_failed_run
    workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
  end

  def retryable_error_class?(error_class)
    self.class.retryable_error_class?(error_class)
  end

  def provider_auth_failure?(run)
    return false if run.agent_provider.blank?

    diagnostic = run.run_diagnostic
    text = [
      run.agent_outcome,
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
