# One persisted outcome taxonomy for grader Steps and their collectors.
#
# A grader is `test_failed` only when Syrus holds a valid process exit status
# (an integer 0..255) AND captured
# evidence of the failure (log output, a log artifact, or a JUnit/JSON
# reference). Everything that merely means "we could not observe the tests
# run" -- missing exit status, worker death, setup or dependency-install
# failure, database lock/resource contention, lost result transport, timeout --
# is never a source-code failure.
class GraderOutcome
  PASSED = "passed".freeze
  TEST_FAILED = "test_failed".freeze
  INFRASTRUCTURE_FAILED = "infrastructure_failed".freeze
  INCONCLUSIVE = "inconclusive".freeze
  CANCELLED = "cancelled".freeze
  ALL = [ PASSED, TEST_FAILED, INFRASTRUCTURE_FAILED, INCONCLUSIVE, CANCELLED ].freeze

  INFRASTRUCTURE_OUTPUT_PATTERNS = [
    /database is locked/i,
    /SQLite3::BusyException/i,
    /Lock wait timeout exceeded/i,
    /Mysql2::Error::(?:TimeoutError|ConnectionError)/i,
    /could not obtain a connection from the pool/i,
    /ActiveRecord::ConnectionTimeoutError/i,
    /no space left on device/i,
    /Could not find .* in locally installed gems/i,
    /An error occurred while installing/i,
    /npm ERR! (?:code E(?:AI_AGAIN|NOTFOUND|CONNRESET|TIMEDOUT)|network)/i,
    /Cannot allocate memory/i
  ].freeze
  INFRASTRUCTURE_RUN_OUTCOMES = %w[worker_died disk_full].freeze

  Result = Data.define(:outcome, :reason, :evidence) do
    def to_h = { "outcome" => outcome, "reason" => reason, "evidence" => evidence }
    def test_failed? = outcome == TEST_FAILED
    def passed? = outcome == PASSED
  end

  class << self
    def for_step(step)
      call(
        details: step.details.to_h,
        state: step.state,
        run_outcome: latest_failed_run_outcome(step)
      )
    end

    # `entry` is a collector iteration entry or Step details.
    def for_entry(entry)
      entry = entry.to_h.stringify_keys
      return Result.new(entry["outcome"], entry["outcome_reason"], {}) if ALL.include?(entry["outcome"])

      status = entry["status"].to_s
      state = status == "passed" ? "succeeded" : (status == "cancelled" ? "cancelled" : "failed")
      call(details: entry, state: state)
    end

    def call(details:, state:, run_outcome: nil)
      details = details.to_h.stringify_keys
      evidence = evidence_for(details, run_outcome)

      return result(PASSED, "grader_passed", evidence) if state.to_s == "succeeded"
      return result(CANCELLED, "grader_cancelled", evidence) if state.to_s == "cancelled" || cancelled?(details)
      return result(INFRASTRUCTURE_FAILED, "worker_died", evidence) if INFRASTRUCTURE_RUN_OUTCOMES.include?(run_outcome.to_s)
      return result(INCONCLUSIVE, "timed_out", evidence) if timed_out?(details)

      output = details["output"].to_s
      return result(INFRASTRUCTURE_FAILED, "infrastructure_output", evidence) if infrastructure_output?(output)
      return result(INCONCLUSIVE, "missing_exit_status", evidence) if details["exit_code"].nil?
      return result(INCONCLUSIVE, "invalid_exit_status", evidence) unless valid_exit_status?(details["exit_code"])
      return result(INCONCLUSIVE, "exit_status_zero_without_pass", evidence) if details["exit_code"].to_i.zero?
      return result(INCONCLUSIVE, "missing_failure_evidence", evidence) unless failure_evidence?(details)

      result(TEST_FAILED, "nonzero_exit_with_evidence", evidence)
    end

    def valid_exit_status?(value)
      return false if value.nil? || value == true || value == false
      return false unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      value.to_i.between?(0, 255)
    end

    def infrastructure_output?(output)
      output.to_s.match?(Regexp.union(INFRASTRUCTURE_OUTPUT_PATTERNS))
    end

    private

    def result(outcome, reason, evidence) = Result.new(outcome, reason, evidence)

    def timed_out?(details)
      details["timed_out"] == true || details["timed_out"].to_s == "true" || GraderFailureSignal.timeout_like_entry?(details)
    end

    def cancelled?(details)
      details["cancelled"] == true || details["operator_killed"] == true || details["stopped"] == true
    end

    def failure_evidence?(details)
      details["output"].to_s.strip.present? ||
        details["log_bytes"].to_i.positive? ||
        details["junit_output"].present? ||
        details["json_output"].present?
    end

    def evidence_for(details, run_outcome)
      {
        "command" => details["command"],
        "source_sha" => details["source_sha"] || details["commit_sha"],
        "worker" => details["worker"] || details["worker_id"],
        "exit_code" => details["exit_code"],
        "timed_out" => details["timed_out"],
        "cancelled" => details["cancelled"],
        "run_outcome" => run_outcome,
        "log_path" => details["log_path"],
        "junit_output" => details["junit_output"],
        "json_output" => details["json_output"]
      }.compact
    end

    def latest_failed_run_outcome(step)
      run = step.runs.where(state: "failed").order(created_at: :desc).first
      return nil unless run

      run.agent_outcome.presence || run.run_failure_classification&.classification
    end
  end
end
