require "fileutils"
require "open3"
require "shellwords"
require "tempfile"
require "timeout"
require "tmpdir"

class BaseRevisionRetry
  TIMEOUT_SECONDS = 10.minutes
  OUTPUT_INLINE_BYTES = 16 * 1024

  Result = Data.define(:ran, :inherited, :reason, :command, :base_failed_identities, :introduced_failed_identities, :output)

  def self.call(...)
    new(...).call
  end

  def initialize(workflow:, grader_step:, base_sha:, failed_cases:, log:)
    @workflow = workflow
    @grader_step = grader_step
    @base_sha = base_sha.to_s
    @failed_cases = Array(failed_cases)
    @log = log
  end

  def call
    return skipped("no_failed_test_cases") if @failed_cases.empty?

    command = focused_command
    return skipped("no_focused_test_command") if command.blank?

    output = +""
    parsed = nil
    Dir.mktmpdir("syrus-brr-") do |dir|
      checkout_path = Pathname.new(dir).join("base")
      git("worktree", "add", "--detach", checkout_path.to_s, @base_sha)
      begin
        @log.call("[brr:#{grader_name}] running failed tests at base #{@base_sha.first(9)}: #{redacted_command(command)}")
        run_command(command, checkout_path, output)
        parsed = parse_result(output, checkout_path)
      ensure
        git("worktree", "remove", "--force", checkout_path.to_s)
      end
    end

    return skipped("base_retry_output_not_parseable", command: command, output: output) unless parsed

    candidate = @failed_cases.map { |test_case| identity_for(test_case) }.compact.uniq.sort
    base = parsed.cases.select { |test_case| %w[failed error].include?(test_case.status) }
                 .map { |test_case| [ test_case.suite_name, test_case.name ].join(0.chr) }
                 .uniq
                 .sort
    introduced = candidate - base
    inherited = candidate.any? && introduced.empty?
    Result.new(
      ran: true,
      inherited: inherited,
      reason: inherited ? "base_retry_failed_cases_match" : "base_retry_found_introduced_cases",
      command: redacted_command(command),
      base_failed_identities: base,
      introduced_failed_identities: introduced,
      output: output_tail(output)
    )
  rescue StandardError => e
    skipped("base_retry_error: #{e.class}: #{e.message}")
  end

  private

  def skipped(reason, command: nil, output: nil)
    Result.new(
      ran: false,
      inherited: false,
      reason: reason,
      command: command && redacted_command(command),
      base_failed_identities: [],
      introduced_failed_identities: [],
      output: output && output_tail(output)
    )
  end

  def focused_command
    config = base_retry_config
    return nil unless config
    return interpolate_explicit_command(config.fetch("command")) if config.fetch("strategy") == "command"
    return files_as_args_command if config.fetch("strategy") == "files_as_args"

    Syrus::PluginRegistry.providers_for(:focused_test_command).each do |provider|
      command = provider.command_for(
        grader_name: grader_name,
        grader_command: @grader_step.details.to_h["command"],
        failed_cases: @failed_cases,
        base_retry: config
      )
      return command.to_s.strip if command.to_s.strip.present?
    rescue StandardError => e
      @log.call("[brr:#{grader_name}] focused_test_command #{provider} declined with #{e.class}: #{e.message}")
    end
    nil
  end

  def base_retry_config
    raw = @grader_step.details.to_h["base_retry"]
    return nil if raw.blank?
    return { "strategy" => "command", "command" => raw } if raw.is_a?(String)

    config = raw.to_h.stringify_keys
    strategy = config["strategy"].to_s
    return nil if strategy.blank?

    config.merge("strategy" => strategy)
  end

  def interpolate_explicit_command(command)
    files = @failed_cases.filter_map { |test_case| test_case["file_path"].presence }.uniq.sort
    command
      .gsub("{files}", Shellwords.join(files))
      .gsub("{failed_count}", @failed_cases.size.to_s)
  end

  def files_as_args_command
    files = @failed_cases.filter_map { |test_case| test_case["file_path"].presence }.uniq.sort
    return nil if files.empty?

    "#{@grader_step.details.to_h['command']} #{Shellwords.join(files)}"
  end

  def run_command(command, chdir, output)
    result = nil
    Timeout.timeout(TIMEOUT_SECONDS) do
      Open3.popen2e(env, "bash", "-c", command, chdir: chdir.to_s) do |stdin, stream, wait_thread|
        stdin.close
        stream.each { |chunk| output << chunk }
        result = wait_thread.value
      end
    end
    result
  rescue Timeout::Error
    output << "\n[brr] timed out after #{TIMEOUT_SECONDS.to_i}s\n"
    nil
  end

  def parse_result(output, checkout_path)
    junit_path = @grader_step.details.to_h["junit_output"].to_s.strip.presence
    if junit_path
      path = checkout_path.join(junit_path)
      return JunitXmlParser.parse(path.read) if path.file?
    end
    Dir.glob(checkout_path.join(".syrus/grade-output/**/*.{xml,junit}").to_s).sort.each do |path|
      return JunitXmlParser.parse(File.read(path))
    rescue JunitXmlParser::ParseError
      next
    end

    parse_output(output)
  rescue JunitXmlParser::ParseError
    parse_output(output)
  end

  def parse_output(output)
    Tempfile.create([ "syrus-brr", ".log" ]) do |file|
      file.write(output)
      file.flush

      Syrus::PluginRegistry.providers_for("test_insights:parser").each do |provider|
        next unless provider.can_parse?(output_path: file.path, format_hint: nil)

        return provider.call(output_path: file.path, format_hint: nil)
      rescue StandardError
        next
      end

      begin
        return JunitXmlParser.parse(output)
      rescue JunitXmlParser::ParseError
        return nil
      end
    end
  end

  def git(*args)
    GitRunner.new.run(*args, chdir: workspace_path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
  end

  def workspace_path
    StepWorkspace.for(@grader_step, log: @log).path
  end

  def env
    ProcessRunner.forwarded_env(
      Steps::Prepare.prep_env_forward,
      extra: WorkspaceDependencyEnv.for(workspace_path).merge(
        Steps::Prepare.prep_extra_env(workflow: @workflow, workspace_path: workspace_path)
      )
    )
  end

  def grader_name
    @grader_step.details.to_h["name"].to_s
  end

  def identity_for(test_case)
    identity = test_case["identity"].to_s
    return identity if identity.present?

    suite_name = test_case["suite_name"].to_s
    name = test_case["name"].to_s
    return nil if suite_name.blank? || name.blank?

    [ suite_name, name ].join(0.chr)
  end

  def output_tail(output)
    output.to_s.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES)
  end

  def redacted_command(command)
    command.to_s.gsub(/(token|password|secret|key)=\S+/i, '\1=[REDACTED]')
  end
end
