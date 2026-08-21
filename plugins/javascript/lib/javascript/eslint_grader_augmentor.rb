module JavaScript
  # Augments grader failure logs with structured details from ESLint's JSON
  # formatter output. When a grader command that invokes ESLint fails, the
  # plain-text transcript may be truncated before every message prints. This
  # augmentor reads JSON report files under .syrus/eslint-json/ and appends a
  # compact message list so the agent sees every lint failure even after a
  # long run. Mirrors Ruby::GraderAugmentor's pattern for RSpec's JSON output.
  #
  # Repos opt in by running eslint with:
  #   eslint --format json --output-file .syrus/eslint-json/report.json
  #
  # Only activates when the grader command contains "eslint" to avoid
  # misidentifying JSON files left over from a prior successful eslint grader
  # run when an unrelated grader later fails in the same iteration.
  class EslintGraderAugmentor
    JSON_REPORT_DIR = ".syrus/eslint-json"

    def self.augment_grader_failure(name:, command:, workspace_path:)
      return nil unless command.include?("eslint")

      json_paths = Pathname.new(workspace_path).join(JSON_REPORT_DIR).glob("*.json")
      return nil if json_paths.empty?

      lines = []
      logged_header = false

      json_paths.each do |path|
        results = JSON.parse(path.read)
        Array(results).each do |file|
          messages = Array(file["messages"])
          next if messages.empty?

          unless logged_header
            lines << "[eslint messages from JSON output]\n"
            logged_header = true
          end

          messages.each do |message|
            lines << message_line(file["filePath"], message)
          end
        end
      rescue JSON::ParserError
        # Partial writes can happen when a grader is interrupted; the text log is authoritative.
      end

      lines.empty? ? nil : lines
    end

    def self.message_line(path, message)
      rule_id = message["ruleId"] || "unknown-rule"
      "#{path}:#{message["line"]}: #{rule_id}: #{message["message"]}\n"
    end
    private_class_method :message_line
  end
end
