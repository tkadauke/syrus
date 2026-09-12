require "shellwords"

module JavaScript
  class FocusedTestCommand
    include Syrus::Plugin::FocusedTestCommand

    TEST_FILE = /\.(?:test|spec)\.[cm]?[jt]sx?\z/.freeze

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
      return nil unless javascript_grader?

      files = failed_test_files
      return nil if files.empty?

      install_prefix = "if [ ! -d node_modules/.bin ] || [ ! -f node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ] || [ package.json -nt node_modules/.package-lock.json ]; then npm ci; fi"
      junit_path = ".syrus/grade-output/#{junit_basename}"
      "#{install_prefix} && mkdir -p #{Shellwords.escape(File.dirname(junit_path))} && npx vitest run --maxWorkers=1 --reporter=default --reporter=junit --outputFile.junit=#{Shellwords.escape(junit_path)} #{Shellwords.join(files)}"
    end

    private

    def javascript_grader?
      @grader_name.match?(/(?:react|vitest|frontend)/i) ||
        @grader_command.match?(/(?:vitest|bin\/test-react)/i)
    end

    def failed_test_files
      @failed_cases.filter_map do |test_case|
        [
          test_case["file_path"].presence,
          test_case["suite_name"].presence,
          test_case["name"].presence
        ].find { |value| value.to_s.match?(TEST_FILE) }
      end.uniq.sort
    end

    def junit_basename
      name = @grader_name.presence || "javascript"
      "#{name.gsub(/[^A-Za-z0-9_.-]+/, '-')}-junit.xml"
    end
  end
end
