module Ruby
  # Augments grader failure logs with structured details from RuboCop's JSON
  # formatter output. When a grader command that invokes RuboCop fails, the
  # plain-text transcript may be truncated before every offense prints. This
  # augmentor reads JSON report files under .syrus/rubocop-json/ and appends a
  # compact offense list so the agent sees every failing cop even after a long
  # run. Mirrors Ruby::GraderAugmentor's pattern for RSpec's JSON output.
  #
  # Repos opt in by running rubocop with:
  #   rubocop --format json --out .syrus/rubocop-json/report.json
  #
  # Only activates when the grader command contains "rubocop" to avoid
  # misidentifying JSON files left over from a prior successful rubocop grader
  # run when an unrelated grader later fails in the same iteration.
  class RubocopGraderAugmentor
    JSON_REPORT_DIR = ".syrus/rubocop-json"

    def self.augment_grader_failure(name:, command:, workspace_path:)
      return nil unless command.include?("rubocop")

      json_paths = Pathname.new(workspace_path).join(JSON_REPORT_DIR).glob("*.json")
      return nil if json_paths.empty?

      lines = []
      logged_header = false

      json_paths.each do |path|
        report = JSON.parse(path.read)
        Array(report["files"]).each do |file|
          offenses = Array(file["offenses"])
          next if offenses.empty?

          unless logged_header
            lines << "[rubocop offenses from JSON output]\n"
            logged_header = true
          end

          offenses.each do |offense|
            lines << offense_line(file["path"], offense)
          end
        end
      rescue JSON::ParserError
        # Partial writes can happen when a grader is interrupted; the text log is authoritative.
      end

      lines.empty? ? nil : lines
    end

    def self.offense_line(path, offense)
      location = offense["location"] || {}
      cop_name = offense["cop_name"] || "unknown-cop"
      "#{path}:#{location["line"]}: #{cop_name}: #{offense["message"]}\n"
    end
    private_class_method :offense_line
  end
end
