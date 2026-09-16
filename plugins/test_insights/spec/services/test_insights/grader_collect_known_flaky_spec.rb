require "rails_helper"
require "tmpdir"

# Core's Adjudicators::KnownFlakyFailure asks :test_evidence providers for
# failing test cases and flakiness history; it never reaches into this
# plugin's models directly. These examples drive that decision through this
# plugin's real provider and real TestInsights data, so they live here rather
# than in core's GraderCollect spec.
RSpec.describe Steps::GraderCollect, "known-flaky test-case failures" do
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
    job.repository.update!(known_flaky_failure_dismissal_enabled: true)
  end

  # Historical cases live on a separate Workflow -- never on `workflow` itself
  # -- so they cannot be mistaken for this iteration's grader Step by
  # `workflow.steps.find_by!(kind: "grader")` (mirrors grader_collect_inherited_spec.rb).
  def seed_flakiness_history!(suite_name:, name:, statuses:)
    history_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")
    history_step = Step.create!(workflow: history_workflow, kind: "grader", position: 1, state: "succeeded", details: { "name" => "history" })
    statuses.each do |status|
      history_run = history_step.runs.create!(job: job, trigger_kind: history_workflow.trigger_kind, state: "succeeded")
      test_run = TestInsights::TestRun.create!(
        run: history_run, repository: job.repository, grader_name: "rspec",
        total_count: 1, passed_count: status == "passed" ? 1 : 0, failed_count: status == "passed" ? 0 : 1
      )
      TestInsights::TestCase.create!(test_run: test_run, repository: job.repository, suite_name: suite_name, name: name, status: status)
    end
  end

  it "dismisses a required grader failure whose only failing test is confirmed flaky" do
    seed_flakiness_history!(
      suite_name: "spec/services/steps/preflight_grader_fanout_spec.rb",
      name: "makes every preflight grader ready as soon as the fanout settles",
      statuses: %w[passed passed passed passed failed]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestInsights::TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(
      test_run: candidate_test_run, repository: job.repository,
      suite_name: "spec/services/steps/preflight_grader_fanout_spec.rb",
      name: "makes every preflight grader ready as soon as the fanout settles",
      status: "failed"
    )
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "exit_code" => 1 }
    )

    expect { handler.call }.not_to raise_error

    artifact = workflow.reload.artifact("known_flaky_grader_failure")
    expect(artifact).to include("grader_names" => [ "rspec" ])
    expect(artifact["tests"].first).to include(
      "suite_name" => "spec/services/steps/preflight_grader_fanout_spec.rb",
      "name" => "makes every preflight grader ready as soon as the fanout settles",
      "confirmed_flaky" => true
    )
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include("treating as known-flaky:")
  end

  it "does not dismiss a required grader failure with no flakiness history yet" do
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestInsights::TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(
      test_run: candidate_test_run, repository: job.repository,
      suite_name: "spec/models/widget_spec.rb", name: "brand new failure", status: "failed"
    )
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")

    expect(workflow.reload.artifact("known_flaky_grader_failure")).to be_nil
  end

  it "does not dismiss when the repository has not opted in" do
    job.repository.update!(known_flaky_failure_dismissal_enabled: false)
    seed_flakiness_history!(
      suite_name: "spec/models/widget_spec.rb", name: "flaky widget test",
      statuses: %w[passed passed failed]
    )
    grader_step = workflow.steps.find_by!(kind: "grader")
    candidate_run = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
    candidate_test_run = TestInsights::TestRun.create!(run: candidate_run, repository: job.repository, grader_name: "rspec", total_count: 1, passed_count: 0, failed_count: 1)
    TestInsights::TestCase.create!(
      test_run: candidate_test_run, repository: job.repository,
      suite_name: "spec/models/widget_spec.rb", name: "flaky widget test", status: "failed"
    )
    grader_step.update!(
      state: "failed",
      details: { "name" => "rspec", "required" => true, "exit_code" => 1 }
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "required graders failed: rspec")
  end
end
