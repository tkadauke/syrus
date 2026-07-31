class RunFailureClassifier
  Result = Data.define(:classification, :confidence, :retryable, :reason, :diagnostic_summary, :classifier_inputs)

  RECENT_LOG_LIMIT = 25

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
  end

  def classify
    case
    when provider_usage_limit?
      result(ProviderUsageLimit::CLASSIFICATION, 0.95, false, "The provider or model usage limit is exhausted.")
    when rate_limited?
      result("rate_limited", 0.90, true, "The run hit an external rate limit.")
    when timeout?
      result("timeout", 0.85, true, "The run failed because an operation timed out.")
    when mcp_sidecar?
      result("mcp_sidecar_failure", 0.75, true, "The agent sidecar failed or disconnected.")
    when process_died?
      result("worker_died", 0.95, true, "The worker or agent process disappeared while the run was active.")
    when branch_diverged?
      result("branch_diverged", 0.95, false, "The PR branch changed before Syrus could push this workflow.")
    when merge_train_rebase_conflict?
      result("merge_train_rebase_conflict", 0.90, false, "The merge-train integration rebase needs operator attention before the train can continue.")
    when merge_train_rebuild_required?
      result("merge_train_rebuild_required", 0.90, false, "The merge-train integration branch must be rebuilt before this workflow can continue.")
    when empty_commit?
      result("empty_commit", 0.85, false, "A git commit or amend was rejected because it would be empty (not a corrupt workspace).")
    when git_state_corrupt?
      result("git_state_corrupt", 0.85, false, "The workspace git state was corrupt or unsafe.")
    when max_turns?
      result("agent_max_turns", 0.90, false, "The agent stopped after reaching the configured turn limit.")
    when argument_list_too_long?
      result("agent_invocation_too_large", 0.90, false, "The agent command line exceeded the OS argument-size limit (the prompt is too large to pass on argv; it must be sent over stdin).")
    when auth_or_config?
      result("provider_auth_or_config", 0.80, false, "The provider authentication or configuration was invalid.")
    when validation_or_user_error?
      result("validation_or_user_error", 0.75, false, "The run failed on validation or user-supplied input.")
    when provider_transient?
      result("provider_transient", 0.75, true, "The provider failed transiently.")
    when database_lock?
      result("database_lock", 0.80, true, "The run failed during a transient database lock or timeout.")
    when git_failure?
      result("git_failure", 0.70, false, "A git operation failed.")
    else
      result("application_error", 0.40, false, "The run failed with an unclassified application error.")
    end
  end

  private

  attr_reader :run

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

  def rate_limited?
    recent_logs.any? { |log| log.kind == "rate_limited" } ||
      text_match?(/rate[ -]?limit|too many requests|quota exceeded|429/i)
  end

  def provider_usage_limit?
    ProviderUsageLimit.detect?(searchable_text) ||
      run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME
  end

  def timeout?
    run.agent_outcome.to_s.match?(/timeout|timed_out/) ||
    diagnostic&.error_class.to_s.match?(/Timeout/) ||
      text_match?(/timed out|timeout|execution expired/i) ||
      spawned_processes.any? { |process| %w[timed_out silent_timed_out].include?(process.outcome) }
  end

  def process_died?
    run.agent_outcome == "worker_died" ||
      text_match?(/ProcessPrunedError|worker died|process (is )?gone|process died|sigkill|killed|terminated|exit status/i) ||
      spawned_processes.any? { |process| %w[aliveness_failed orphaned stopped operator_killed].include?(process.outcome) }
  end

  def branch_diverged?
    diagnostic&.error_class.to_s.match?(/Steps::PrOpen::BranchDiverged/) ||
      text_match?(/PR branch changed before Syrus could push|branch diverged|non-fast-forward/i)
  end

  def merge_train_rebuild_required?
    text_match?(
      /merge_train: base moved .* rebuild required|merge_train: missing built base SHA; rebuild required|merge_train_reconcile: built integration branch .* rebuild required/i
    )
  end

  def merge_train_rebase_conflict?
    text_match?(
      /merge_train: rebase for .* was not completed|merge_train: integrating .* left a dirty worktree|merge_train: .* was not rebased onto the integration branch/i
    )
  end

  def empty_commit?
    # A commit/amend git refused because it would introduce no changes — a
    # benign situation (e.g. relabeling an empty "re-trigger CI" commit), NOT
    # workspace corruption. Must be checked before git_state_corrupt?, which
    # matches every GitRunner::GitError.
    text_match?(/would make it empty|nothing to commit|no changes added to commit/i)
  end

  def git_state_corrupt?
    run.agent_outcome == "git_state_corrupt" ||
    diagnostic&.error_class.to_s.match?(/GitRunner::GitError|AgentBrokeGitState/) ||
      text_match?(/git state corrupt|merge conflict|conflict markers|orphan|detached head|no common ancestor|not a git repository|unmerged files|refusing to fetch|merge-base|bad revision|unrelated histories/i)
  end

  def max_turns?
    run.agent_outcome == "error_max_turns" || text_match?(/max turns|turn limit/i)
  end

  def auth_or_config?
    # NOTE: match specific configuration phrasings, not a bare `config`
    # substring — the latter matched the `--mcp-config` flag echoed in an
    # unrelated command line (e.g. the Errno::E2BIG argv-too-long failure)
    # and mislabeled it as an auth/config problem.
    text_match?(/auth|oauth|token|api key|unauthorized|forbidden|permission denied|not configured|misconfigur|invalid configuration|missing.+credential|invalid.+credential|mcp.+initialize|connection closed: initialize/i)
  end

  def argument_list_too_long?
    diagnostic&.error_class.to_s.match?(/Errno::E2BIG/) ||
      text_match?(/Errno::E2BIG|argument list too long/i)
  end

  def validation_or_user_error?
    diagnostic&.error_class.to_s.match?(/ActiveRecord::RecordInvalid|ActiveModel::ValidationError|ArgumentError|URI::InvalidURIError/) ||
      text_match?(/validation_failed|record invalid|invalid params|invalid input|cannot be blank|must be present|bad request|unprocessable/i)
  end

  def provider_transient?
    return false if run.agent_provider.blank?

    text_match?(%r{
      overloaded|
      temporar(?:y|ily)|
      transient|
      retry\ later|
      service\ unavailable|
      bad\ gateway|
      gateway\ timeout|
      connection\ reset|
      connection\ refused|
      network\ error|
      (?:status|http|code)\s*[:=]?\s*5\d\d|
      5xx
    }ix)
  end

  def database_lock?
    diagnostic&.error_class.to_s.match?(/Deadlocked|LockWaitTimeout|StatementTimeout/) ||
      text_match?(/database is locked|SQLite3::BusyException|Deadlocked|LockWaitTimeout|StatementTimeout/i)
  end

  def mcp_sidecar?
    run.agent_outcome == "mcp_sidecar_failed" ||
      text_match?(
        /\[mcp_servers\].*failed|No such tool available: mcp__syrus-mcp-sidecar|mcp.*sidecar.*failed|sidecar.*failed|initialize response|connection closed: initialize/i
      )
  end

  def git_failure?
    diagnostic&.error_class.to_s.include?("Git") || text_match?(/\bgit\b.*(failed|error|fatal)/i)
  end

  def text_match?(pattern)
    searchable_text.match?(pattern)
  end

  def searchable_text
    @searchable_text ||= [
      run.agent_outcome,
      run.agent_summary,
      run.agent_pr_title,
      run.agent_pr_body,
      diagnostic&.error_class,
      diagnostic&.error_message,
      diagnostic&.error_backtrace,
      diagnostic&.repo_snapshot&.dig("run_outcome"),
      diagnostic&.repo_snapshot&.dig("workflow_failure_reason"),
      recent_logs.map(&:chunk)
    ].flatten.compact.join("\n")
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
      "job_log_kinds" => recent_logs.map(&:kind).compact,
      "spawned_process_outcomes" => spawned_processes.map(&:outcome).compact.uniq
    }
  end

  def diagnostic
    @diagnostic ||= run.run_diagnostic
  end

  def recent_logs
    @recent_logs ||= begin
      logs = if run.association(:job_logs).loaded?
        run.job_logs
      else
        run.job_logs.order(sequence: :desc).limit(RECENT_LOG_LIMIT).to_a.reverse
      end
      logs.last(RECENT_LOG_LIMIT)
    end
  end

  def spawned_processes
    @spawned_processes ||= begin
      return [] unless run.respond_to?(:spawned_processes)

      processes = if run.association(:spawned_processes).loaded?
        run.spawned_processes
      else
        run.spawned_processes.recent_or_active.to_a
      end
      processes.sort_by { |process| process.finished_at || process.started_at || Time.at(0) }
    end
  end
end
