module Python
  # Augments grader failure logs with structured details from pytest's
  # pytest-json-report plugin output. When a grader command that invokes
  # pytest fails, the plain-text transcript may be truncated before the
  # summary prints. This augmentor reads JSON report files under
  # .syrus/pytest-json/ and appends a compact failure list so the agent sees
  # every failed test even after a long run. Mirrors Ruby::GraderAugmentor's
  # pattern for RSpec's per-worker JSON output.
  #
  # Repos opt in by running pytest with:
  #   pytest --json-report --json-report-file=.syrus/pytest-json/report.json
  #
  # Only activates when the grader command contains "pytest" to avoid
  # misidentifying JSON files left over from a prior successful pytest grader
  # run when an unrelated grader later fails in the same iteration.
  class GraderAugmentor
    JSON_REPORT_DIR = ".syrus/pytest-json"
    FAILED_OUTCOMES = %w[failed error].freeze

    def self.augment_grader_failure(name:, command:, workspace_path:)
      return nil unless command.include?("pytest")

      json_paths = Pathname.new(workspace_path).join(JSON_REPORT_DIR).glob("*.json")
      return nil if json_paths.empty?

      lines = []
      logged_header = false

      json_paths.each do |path|
        report = JSON.parse(path.read)
        failures = Array(report["tests"]).select { |test| FAILED_OUTCOMES.include?(test["outcome"]) }
        next if failures.empty?

        unless logged_header
          lines << "[pytest failures from JSON report]\n"
          logged_header = true
        end

        failures.each do |test|
          test_name = test["nodeid"] || "unknown test"
          message = failure_message(test)
          lines << (message ? "FAILED: #{test_name} — #{message}\n" : "FAILED: #{test_name}\n")
        end
      rescue JSON::ParserError
        # Partial writes can happen when a grader is interrupted; the text log is authoritative.
      end

      lines.empty? ? nil : lines
    end

    def self.failure_message(test)
      call = test["call"] || {}
      crash_message = call.dig("crash", "message")
      return crash_message if crash_message.present?

      call["longrepr"].to_s.lines.first&.strip.presence
    end
    private_class_method :failure_message
  end
end
