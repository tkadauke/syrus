class RunFailureClassifier
  Result = Data.define(:classification, :confidence, :retryable, :reason, :diagnostic_summary, :classifier_inputs)

  def self.classify(run)
    new(run).classify
  end

  def self.persist!(run)
    result = classify(run)
    record = run.run_failure_classification || run.build_run_failure_classification
    record.assign_attributes(
      classification: result.classification,
      confidence: result.confidence,
      retryable: result.retryable,
      reason: result.reason,
      diagnostic_summary: result.diagnostic_summary,
      classifier_inputs: result.classifier_inputs,
      classified_at: Time.current
    )
    record.save!
    record
  end

  def initialize(run)
    @run = run
    @diagnostic = run.run_diagnostic
  end

  def classify
    case
    when worker_died?
      result("worker_died", 0.95, true, "The worker process disappeared while the run was active.")
    when rate_limited?
      result("rate_limited", 0.90, true, "The run hit an external rate limit.")
    when max_turns?
      result("agent_max_turns", 0.90, false, "The agent stopped after reaching the configured turn limit.")
    when git_state_corrupt?
      result("git_state_corrupt", 0.85, false, "The workspace git state was corrupt or unsafe.")
    when timeout?
      result("timeout", 0.80, true, "The run failed because an operation timed out.")
    when database_lock?
      result("database_lock", 0.80, true, "The run failed during a transient database lock or timeout.")
    when mcp_sidecar?
      result("mcp_sidecar_failure", 0.75, true, "The agent sidecar failed or disconnected.")
    when git_failure?
      result("git_failure", 0.70, false, "A git operation failed.")
    else
      result("application_error", 0.40, false, "The run failed with an unclassified application error.")
    end
  end

  private

  attr_reader :run, :diagnostic

  def result(classification, confidence, retryable, reason)
    Result.new(
      classification: classification,
      confidence: confidence,
      retryable: retryable,
      reason: reason,
      diagnostic_summary: diagnostic_summary,
      classifier_inputs: classifier_inputs
    )
  end

  def worker_died?
    run.agent_outcome == "worker_died" || text.match?(/ProcessPrunedError|worker died|process (is )?gone|SIGKILL/i)
  end

  def rate_limited?
    run.job_logs.any? { |log| log.kind == "rate_limited" } || text.match?(/rate limit|too many requests|429/i)
  end

  def max_turns?
    run.agent_outcome == "error_max_turns" || text.match?(/max turns|turn limit/i)
  end

  def git_state_corrupt?
    run.agent_outcome == "git_state_corrupt" || text.match?(/git state corrupt|not a git repository|bad revision|unrelated histories/i)
  end

  def timeout?
    diagnostic&.error_class.to_s.match?(/Timeout/) || text.match?(/timed out|timeout|execution expired/i)
  end

  def database_lock?
    diagnostic&.error_class.to_s.match?(/Deadlocked|LockWaitTimeout|StatementTimeout/) ||
      text.match?(/database is locked|SQLite3::BusyException|Deadlocked|LockWaitTimeout|StatementTimeout/i)
  end

  def mcp_sidecar?
    text.match?(/mcp|sidecar|initialize response|connection closed/i)
  end

  def git_failure?
    diagnostic&.error_class.to_s.include?("Git") || text.match?(/\bgit\b.*(failed|error|fatal)/i)
  end

  def text
    @text ||= [
      run.agent_outcome,
      diagnostic&.error_class,
      diagnostic&.error_message,
      diagnostic&.repo_snapshot&.dig("run_outcome"),
      diagnostic&.repo_snapshot&.dig("workflow_failure_reason")
    ].compact.join("\n")
  end

  def diagnostic_summary
    bits = []
    bits << "#{diagnostic.error_class}: #{diagnostic.error_message}" if diagnostic
    bits << "agent_outcome=#{run.agent_outcome}" if run.agent_outcome.present?
    bits << "trigger=#{run.trigger_kind}"
    bits << "step=#{run.step&.kind}" if run.step
    bits.join(" | ").truncate(1_000)
  end

  def classifier_inputs
    {
      "run_id" => run.id,
      "run_state" => run.state,
      "trigger_kind" => run.trigger_kind,
      "agent_provider" => run.agent_provider,
      "agent_outcome" => run.agent_outcome,
      "step_kind" => run.step&.kind,
      "workflow_id" => run.workflow_id,
      "workflow_trigger_kind" => run.workflow&.trigger_kind,
      "workflow_state" => run.workflow&.state,
      "workflow_failure_reason" => run.workflow&.failure_reason,
      "diagnostic_id" => diagnostic&.id,
      "error_class" => diagnostic&.error_class,
      "error_message" => diagnostic&.error_message&.truncate(500),
      "job_log_kinds" => run.job_logs.order(created_at: :desc).limit(20).map(&:kind).compact
    }
  end
end
