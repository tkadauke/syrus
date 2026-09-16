# Validates and records one agent-run isolated repro attempt (EPIC-362):
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
#   - The raw command and output are stored verbatim (via the :test_evidence
#     provider), not a prose summary, so the record is auditable after the
#     fact.
class IsolatedReproRecorder
  Result = Struct.new(:ok, :error, :evidence, keyword_init: true) do
    def ok? = ok
  end

  def self.call(...)
    new(...).call
  end

  def initialize(run:, grader_name:, suite_name:, name:, reproduced:, command:, output:, exit_status: nil)
    @run = run
    @workflow = run.workflow
    @job = run.job
    @repository = @job&.repository
    @grader_name = grader_name.to_s.strip
    @suite_name = suite_name.to_s.strip
    @test_name = name.to_s.strip
    @reproduced = reproduced
    @command = command.to_s
    @output = output.to_s
    @exit_status = exit_status
  end

  def call
    return failure("grader_name is required") if @grader_name.empty?
    return failure("suite_name is required") if @suite_name.empty?
    return failure("name is required") if @test_name.empty?
    return failure("command is required") if @command.strip.empty?
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
    unless failing_tests.any? { |test_case| test_case["suite_name"] == @suite_name && test_case["name"] == @test_name }
      return failure("#{@suite_name}##{@test_name} is not among the currently failing tests for grader #{@grader_name.inspect}")
    end

    provider = TestEvidenceLookup.test_evidence_providers.find { |candidate| candidate.respond_to?(:record_isolated_repro!) }
    return failure("no test_evidence provider available to record isolated repro attempts") unless provider

    provider.record_isolated_repro!(
      repository: @repository,
      job: @job,
      workflow: @workflow,
      run: @run,
      grader_name: @grader_name,
      suite_name: @suite_name,
      name: @test_name,
      sha: current_sha,
      reproduced: !!@reproduced,
      command: @command,
      output: @output,
      exit_status: @exit_status
    )

    Result.new(ok: true, evidence: {
      sha: current_sha,
      grader_name: @grader_name,
      suite_name: @suite_name,
      name: @test_name,
      reproduced: !!@reproduced
    })
  end

  private

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
