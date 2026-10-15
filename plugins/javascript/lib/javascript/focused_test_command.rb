require "shellwords"

module JavaScript
  class FocusedTestCommand
    include Syrus::Plugin::FocusedTestCommand

    TEST_FILE = /\.(?:test|spec)\.[cm]?[jt]sx?\z/.freeze

    def self.command_for(grader_name:, grader_command:, failed_cases:, base_retry:, project_path: nil)
      new(grader_name: grader_name, grader_command: grader_command, failed_cases: failed_cases, base_retry: base_retry, project_path: project_path).command
    end

    def initialize(grader_name:, grader_command:, failed_cases:, base_retry:, project_path: nil)
      @grader_name = grader_name.to_s
      @grader_command = grader_command.to_s
      @failed_cases = Array(failed_cases)
      @base_retry = base_retry.to_h.stringify_keys
      @project_path = project_path.to_s.strip.presence
    end

    def command
      return nil unless @base_retry["strategy"] == "plugin"
      return nil unless javascript_grader?

      files = failed_test_files
      return nil if files.empty?

      install_prefix = JavaScript::PrepareDetector.shell_fresh_install_command
      junit_path = project_path_from_workspace(".syrus/grade-output/#{junit_basename}")
      command = "#{install_prefix} && mkdir -p #{Shellwords.escape(File.dirname(junit_path))} && npx vitest run --maxWorkers=1 --reporter=default --reporter=junit --outputFile.junit=#{Shellwords.escape(junit_path)} #{Shellwords.join(files)}"
      @project_path ? "cd #{Shellwords.escape(@project_path)} && #{command}" : command
    end

    private

    def javascript_grader?
      @grader_name.match?(/(?:react|vitest|frontend)/i) ||
        @grader_command.match?(/vitest/i)
    end

    def failed_test_files
      @failed_cases.filter_map do |test_case|
        [
          test_case["file_path"].presence,
          test_case["suite_name"].presence,
          test_case["name"].presence
        ].find { |value| value.to_s.match?(TEST_FILE) }
      end.map { |path| project_relative_path(path) }.uniq.sort
    end

    def project_relative_path(path)
      return path unless @project_path

      path.delete_prefix("#{@project_path}/")
    end

    def project_path_from_workspace(path)
      return path unless @project_path

      "#{'../' * Pathname.new(@project_path).each_filename.count}#{path}"
    end

    def junit_basename
      name = @grader_name.presence || "javascript"
      "#{name.gsub(/[^A-Za-z0-9_.-]+/, '-')}-junit.xml"
    end
  end
end
