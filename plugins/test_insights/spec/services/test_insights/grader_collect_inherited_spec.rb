require "rails_helper"
require "tmpdir"

# Core decides whether a failed grader case is inherited from the base
# revision or introduced by the branch; it asks :test_evidence providers for
# the case history. These examples drive that decision through this plugin's
# real provider, so they live here rather than in core's GraderCollect spec.
RSpec.describe Steps::GraderCollect, "inherited test-case failures" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:loop_id) { SecureRandom.uuid }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 101,
      iteration: 1,
      loop_id: loop_id
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-grader-collect") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 100,
      iteration: 1,
      loop_id: loop_id,
      state: "succeeded",
      details: { "name" => "tests", "required" => true }
    )
    fake_ws = instance_double(WorkflowWorkspace, path: @ws_path, base_ref: "origin/main")
    git = instance_double(GitRunner, run: "abc123\n")
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(GitRunner).to receive(:new).and_return(git)
  end

  it "passes test-case grader failures only when failed cases match the base revision" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    base_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    base_step = Step.create!(workflow: base_workflow, kind: "grader", position: 1, state: "failed", details: { "name" => "rspec", "failures" => "allow_inherited" })
    base_run = base_step.runs.create!(job: job, trigger_kind: "main_grader", state: "failed")
    base_test_run = TestInsights::TestRun.create!(run: base_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(test_run: base_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Widget fails", status: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: base_workflow,
      step: base_step,
      run: base_run,
      commit_sha: "main123",
      grader_fingerprint: "base-fp",
      grader_name: "rspec",
      required: true,
      status: "failed",
      checked_at: Time.current
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestInsights::TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(test_run: candidate_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Widget fails", status: "failed")
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "junit_output" => "tmp/rspec.xml", "exit_code" => 1 }
    )

    expect { handler.call }.not_to raise_error

    classification = workflow.reload.artifact("inherited_main_branch_grader_failure")["classifications"].first
    expect(classification).to include(
      "failures" => "allow_inherited",
      "reason" => "failed_cases_match_base",
      "candidate_failed_case_count" => 1,
      "base_failed_case_count" => 1
    )
  end

  it "does not pass test-case grader failures that introduce a new failed case" do
    job.repository.update!(ci_health: "healthy", grader_health: "broken", last_health_checked_sha: "main123")
    base_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    base_step = Step.create!(workflow: base_workflow, kind: "grader", position: 1, state: "failed", details: { "name" => "rspec", "failures" => "allow_inherited" })
    base_run = base_step.runs.create!(job: job, trigger_kind: "main_grader", state: "failed")
    base_test_run = TestInsights::TestRun.create!(run: base_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(test_run: base_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "Old failure", status: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: job,
      workflow: base_workflow,
      step: base_step,
      run: base_run,
      commit_sha: "main123",
      grader_fingerprint: "base-fp",
      grader_name: "rspec",
      required: true,
      status: "failed",
      checked_at: Time.current
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: job.repository,
      sha: "main123",
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestInsights::TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(test_run: candidate_test_run, repository: job.repository, suite_name: "spec/models/widget_spec.rb", name: "New failure", status: "failed")
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "failures" => "allow_inherited", "junit_output" => "tmp/rspec.xml", "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")
  end
end
