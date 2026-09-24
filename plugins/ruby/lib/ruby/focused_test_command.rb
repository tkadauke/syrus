require "shellwords"

module Ruby
  class FocusedTestCommand
    include Syrus::Plugin::FocusedTestCommand

    def self.command_for(grader_name:, grader_command:, failed_cases:, base_retry:)
      new(grader_name: grader_name, grader_command: grader_command, failed_cases: failed_cases, base_retry: base_retry).command
    end

    def initialize(grader_name:, grader_command:, failed_cases:, base_retry:)
      @grader_name = grader_name.to_s
      @grader_command = grader_command.to_s
      @failed_cases = Array(failed_cases)
      @base_retry = base_retry.to_h.stringify_keys
    end

    def command
      return nil unless @base_retry["strategy"] == "plugin"
      return nil unless rspec_grader?

      files = failed_spec_files
      return nil if files.empty?

      "bundle exec rspec #{Shellwords.join(files)}"
    end

    private

    def rspec_grader?
      @grader_name.include?("rspec") || @grader_command.match?(/\brspec\b/)
    end

    def failed_spec_files
      @failed_cases.filter_map do |test_case|
        path = test_case["file_path"].presence || test_case["suite_name"].presence
        path if path.to_s.end_with?("_spec.rb")
      end.uniq.sort
    end
  end
end
