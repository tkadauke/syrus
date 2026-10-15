require "open3"
require "timeout"

# Validates and records one agent-run isolated repro attempt:
# "I ran this exact failing example against this exact failing SHA in
# isolation, and it did/did not reproduce." Backs the record_isolated_repro
# MCP tool.
#
# The whole point of this class is the guardrails that keep this from
# becoming the "agent declares flaky" idea Syrus already rejected elsewhere:
# every check here fails closed (`Result.failure`), and none of them trust
# anything the agent merely *says* over what Syrus can independently observe.
#
#   - The SHA an isolated repro attempt gets credited against is never taken
#     from the agent's input -- it is read straight from `git rev-parse HEAD`
#     in the workflow's own workspace, then required to equal the exact SHA
#     the last grading iteration actually failed at
#     (GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY). That single check
#     rejects both a repro run against the wrong SHA and one recorded after
#     the agent's own fix commits exist: either one moves HEAD away from the
#     graded SHA.
#   - The (suite_name, name) pair has to be among the tests a real, just-run
#     grader Step actually reported as failing -- not merely asserted by the
#     agent -- so a record cannot be manufactured for a test that never
#     failed.
#   - Syrus executes the submitted command itself. The provider stores the
#     observed output and exit status, and a claimed result that disagrees
#     with that exit status is rejected.
class IsolatedReproRecorder
  REPRO_TIMEOUT = 10.minutes
  Result = Struct.new(:ok, :error, :evidence, keyword_init: true) do
    def ok? = ok
  end

  def self.call(...)
    new(...).call
  end

  def initialize(run:, grader_name:, suite_name:, name:, reproduced:, command: nil, output: nil, exit_status: nil)
    @run = run
    @workflow = run.workflow
    @job = run.job
    @repository = @job&.repository
    @grader_name = grader_name.to_s.strip
    @suite_name = suite_name.to_s.strip
    @test_name = name.to_s.strip
    @reproduced = reproduced
    @command = command.to_s
    @exit_status = exit_status
  end

  def call
    return failure("grader_name is required") if @grader_name.empty?
    return failure("suite_name is required") if @suite_name.empty?
    return failure("name is required") if @test_name.empty?
    return failure("no workflow for this run") unless @workflow
    return failure("no repository for this run") unless @repository

    known_failing_sha = @workflow.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY).presence
    return failure("no known failing grade SHA recorded for this workflow yet") unless known_failing_sha

    current_sha = current_workspace_sha
    return failure("could not determine the current workspace HEAD") if current_sha.blank?

    unless current_sha == known_failing_sha
      return failure(
        "workspace HEAD (#{current_sha.first(9)}) no longer matches the last graded SHA " \
        "(#{known_failing_sha.first(9)}) -- record an isolated repro attempt before making any fix commits"
      )
    end

    grader_step = latest_failed_grader_step
    return failure("no failed grader Step named #{@grader_name.inspect} found for this workflow") unless grader_step

    grader_run = grader_step.runs.order(:created_at).last
    return failure("no Run recorded for grader #{@grader_name.inspect}") unless grader_run

    failing_tests = TestEvidenceLookup.failed_test_cases_for(grader_run, @grader_name)
    failing_test = failing_tests.find { |test_case| test_case["suite_name"] == @suite_name && test_case["name"] == @test_name }
    unless failing_test
      return failure("#{@suite_name}##{@test_name} is not among the currently failing tests for grader #{@grader_name.inspect}")
    end

    trusted_command = isolated_command_for(grader_step, failing_test)
    return failure("no focused-test provider can derive an isolated command for this failing test") if trusted_command.blank?
    if @command.present? && @command.strip != trusted_command
      return failure("submitted command does not match the Syrus-derived isolated test command")
    end

    provider = TestEvidenceLookup.test_evidence_providers.find { |candidate| candidate.respond_to?(:record_isolated_repro!) }
    return failure("no test_evidence provider available to record isolated repro attempts") unless provider

    observed_output, observed_exit_status = execute_repro(trusted_command)
    observed_reproduced = observed_exit_status != 0
    return failure("reported reproduced result does not match Syrus-observed exit status") unless !!@reproduced == observed_reproduced
    if !@exit_status.nil? && @exit_status.to_i != observed_exit_status
      return failure("reported exit_status does not match Syrus-observed exit status")
    end
    provider.record_isolated_repro!(
      repository: @repository,
      job: @job,
      workflow: @workflow,
      run: @run,
      grader_name: @grader_name,
      suite_name: @suite_name,
      name: @test_name,
      sha: current_sha,
      reproduced: observed_reproduced,
      command: trusted_command,
      output: observed_output,
      exit_status: observed_exit_status
    )

    Result.new(ok: true, evidence: {
      sha: current_sha,
      grader_name: @grader_name,
      suite_name: @suite_name,
      name: @test_name,
      reproduced: observed_reproduced
    })
  end

  private

  def isolated_command_for(grader_step, failing_test)
    Syrus::PluginRegistry.providers_for(:focused_test_command).each do |provider|
      next unless provider.respond_to?(:isolated_command_for)

      command = provider.isolated_command_for(
        grader_name: @grader_name,
        grader_command: grader_step.details.to_h["command"].to_s,
        test_case: failing_test
      )
      return command.to_s.strip if command.to_s.strip.present?
    rescue StandardError => e
      Rails.logger.warn("[IsolatedReproRecorder] focused command provider #{provider} failed: #{e.class}: #{e.message}")
    end
    nil
  end

  def execute_repro(command)
    output = nil
    status = nil
    Timeout.timeout(REPRO_TIMEOUT) do
      output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, "bash", "-c", command, chdir: WorkflowWorkspace.path_for(@workflow).to_s)
    end
    [ output.to_s, status.exitstatus ]
  rescue Timeout::Error
    [ "isolated repro timed out after #{REPRO_TIMEOUT.to_i}s", 124 ]
  rescue SystemCallError => e
    [ "isolated repro could not start: #{e.message}", 126 ]
  end

  def failure(message)
    Result.new(ok: false, error: message)
  end

  def current_workspace_sha
    workspace_path = WorkflowWorkspace.path_for(@workflow)
    return nil unless workspace_path.directory?

    GitRunner.new.run("rev-parse", "HEAD", chdir: workspace_path.to_s).strip.presence
  rescue GitRunner::GitError
    nil
  end

  def latest_failed_grader_step
    TestEvidenceLookup.failed_grader_steps(@workflow)
                       .select { |candidate| candidate.details.to_h["name"].to_s == @grader_name }
                       .max_by(&:created_at)
  end
end
