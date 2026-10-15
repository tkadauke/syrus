require "digest"
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

    def self.isolated_command_for(grader_name:, grader_command:, test_case:)
      file = test_case.to_h.stringify_keys["file_path"].presence || test_case.to_h.stringify_keys["suite_name"].presence
      name = test_case.to_h.stringify_keys["name"].presence
      return nil unless file.to_s.end_with?("_spec.rb") && name

      command = new(
        grader_name: grader_name,
        grader_command: grader_command,
        failed_cases: [ test_case ],
        base_retry: { "strategy" => "plugin" }
      ).command
      "#{command} --example #{Shellwords.escape(name)}" if command.present?
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

      bundler_env = 'BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle"'
      args = explicit_rspec_tag_args
      rspec_args = args.present? ? Shellwords.join([ *args, *files ]) : "#{ci_only_tag_args} #{Shellwords.join(files)}"
      "export RAILS_ENV=test #{ci_only_env} COVERAGE=false TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-#{test_env_number(files)}}; " \
        "(#{bundler_env} bundle check || #{bundler_env} bundle install --jobs \"${BUNDLE_INSTALL_JOBS:-1}\") && " \
        "#{rails_prepare_command} #{bundler_env} #{rspec_command} #{rspec_args}"
    end

    private

    def rspec_grader?
      @grader_name.include?("rspec") || @grader_command.match?(/\brspec\b/)
    end

    def rspec_command
      return "bin/rspec-worker" if @grader_command.match?(/\bbin\/rspec-worker\b/)

      "bundle exec rspec"
    end

    def rails_prepare_command
      "if [ -x bin/rails ] && [ -f config/database.yml ]; then bin/rails db:test:prepare; fi &&"
    end

    def test_env_number(files)
      "_syrus_flaky_#{Digest::SHA1.hexdigest(([@grader_name] + files).join("\0"))[0, 8]}"
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
      deconflicted_tag_args(args)
    rescue ArgumentError
      nil
    end

    # A generated grader command can hold more than one rspec invocation. The
    # rspec-ci grader runs the parallel pass with `--tag ~ci_only` and then the
    # serial ci-only pass with `--tag ci_only`, so scraping every `--tag` out of
    # it yields `--tag ~ci_only --tag ci_only`. Handing both to a single rspec
    # run asks for examples that are ci_only and not ci_only at once, which
    # matches nothing: the focused base-revision retry ran zero examples,
    # produced no parseable result, and was recorded as
    # `base_retry_output_not_parseable`. With no base comparison the grader
    # could never apply its `allow_inherited` policy, so an inherited or flaky
    # failure was never dismissed and the main branch stayed red.
    #
    # Scraped tags are only a hint about what the grader meant. When they
    # contradict themselves, drop them and fall back to the tag implied by the
    # grader's own identity, which cannot contradict itself.
    def deconflicted_tag_args(args)
      return nil if args.blank?

      tags = []
      rest = []
      index = 0
      while index < args.length
        if args[index] == "--tag" && args[index + 1].present?
          tags << args[index + 1]
          index += 2
        else
          rest << args[index]
          index += 1
        end
      end

      by_name = tags.group_by { |tag| tag.to_s.delete_prefix("~") }
      return nil if by_name.any? { |_, group| group.map { |tag| tag.to_s.start_with?("~") }.uniq.size > 1 }

      (tags.uniq.flat_map { |tag| [ "--tag", tag ] } + rest).presence
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
