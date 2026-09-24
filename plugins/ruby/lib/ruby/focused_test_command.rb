require "shellwords"

module Ruby
  class FocusedTestCommand
    include Syrus::Plugin::FocusedTestCommand

    def self.command_for(grader_name:, grader_command:, failed_cases:, base_retry:)
      new(grader_name: grader_name, grader_command: grader_command, failed_cases: failed_cases, base_retry: base_retry).command
    end

    def self.prepare_command_for(grader_name:, grader_command:)
      return nil unless grader_name.to_s.include?("rspec") || grader_command.to_s.match?(/\brspec\b/)

      "if [ -x bin/rails ] && [ -f config/database.yml ]; then RAILS_ENV=test bin/rails db:test:prepare; fi"
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

      args = explicit_rspec_tag_args
      rspec_args = args.present? ? Shellwords.join([ *args, *files ]) : "#{ci_only_tag_args} #{Shellwords.join(files)}"
      "#{ci_only_env} COVERAGE=false bundle exec rspec #{rspec_args}"
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

    def explicit_rspec_tag_args
      args = []
      tokens = Shellwords.split(@grader_command)
      tokens.each_with_index do |token, index|
        if token == "--tag" && tokens[index + 1].present?
          args.concat([ token, tokens[index + 1] ])
        elsif token.start_with?("RSPEC_TAG_ARGS=")
          args.concat(Shellwords.split(token.delete_prefix("RSPEC_TAG_ARGS=")))
        end
      end
      args.presence
    rescue ArgumentError
      nil
    end

    def ci_only_env
      ci_only_grader? ? "RUN_CI_ONLY_SPECS=true" : "RUN_CI_ONLY_SPECS=false"
    end

    def ci_only_tag_args
      ci_only_grader? ? "--tag ci_only" : "--tag ~ci_only"
    end

    def ci_only_grader?
      @grader_name.include?("rspec-ci") ||
        @grader_command.include?("RUN_CI_ONLY_SPECS=true") ||
        @grader_command.include?("--tag ci_only")
    end
  end
end
