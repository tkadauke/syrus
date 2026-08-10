module SyrusRails
  # Augments grader failure logs with structured details from RSpec's JSON
  # formatter output. When a grader command that invokes RSpec fails, the
  # plain-text transcript may be truncated before the summary prints. This
  # augmentor reads the per-worker JSON files that bin/rspec-fast (and
  # bin/rspec-ci) write to .syrus/rspec-json/ and appends a compact failure
  # list so the agent sees every failed example even after a long run.
  #
  # Only activates when the grader command contains "rspec" to avoid
  # misidentifying JSON files left over from a prior successful rspec grader
  # run when an unrelated grader later fails in the same iteration.
  class GraderAugmentor
    RSPEC_JSON_DIR = ".syrus/rspec-json"

    def self.augment_grader_failure(name:, command:, workspace_path:)
      return nil unless command.include?("rspec")

      json_paths = Pathname.new(workspace_path).join(RSPEC_JSON_DIR).glob("*.json")
      return nil if json_paths.empty?

      lines = []
      logged_header = false

      json_paths.each do |path|
        results = JSON.parse(path.read)
        failures = results.dig("examples")&.select { |ex| ex["status"] == "failed" } || []
        next if failures.empty?

        unless logged_header
          lines << "[rspec failures from JSON output]\n"
          logged_header = true
        end

        failures.each do |failure|
          lines << "#{failure["full_description"]}\n"
          lines << "  #{failure.dig("exception", "message")}\n" if failure.dig("exception", "message")
          lines << "  #{failure["location"]}\n" if failure["location"]
        end
      rescue JSON::ParserError
        # Partial writes can happen when a grader is interrupted; the text log is authoritative.
      end

      lines.empty? ? nil : lines
    end
  end
end
