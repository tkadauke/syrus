require "rails_helper"

RSpec.describe Workflows::LifecyclePropagation do
  let(:job) { Factories.job_record(state: "queued") }
  let!(:previous_workflow) do
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "failed",
      failure_reason: GraderLoopProgress::NO_PROGRESS_REASON,
      artifacts: {
        GraderLoopProgress::STOP_ARTIFACT_KEY => {
          "reason" => GraderLoopProgress::NO_PROGRESS_REASON,
          "explanation" => "failing set unchanged"
        }
      }
    )
  end

  def mark_job_for_grader_loop_attention!
    job.update!(
      needs_attention: true,
      needs_attention_reason: GraderLoopProgress::NO_PROGRESS_REASON,
      needs_attention_since: 1.hour.ago
    )
  end

  it "clears stale grader-loop attention only when a new queued workflow starts" do
    mark_job_for_grader_loop_attention!
    stop_artifact = previous_workflow.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY)

    current_workflow = Workflow.create!(job: job, trigger_kind: "initial")

    expect(job.reload).to have_attributes(
      needs_attention: true,
      needs_attention_reason: GraderLoopProgress::NO_PROGRESS_REASON
    )
    expect(job.needs_attention_since).to be_present

    current_workflow.start!

    expect(job.reload).to have_attributes(
      needs_attention: false,
      needs_attention_reason: nil,
      needs_attention_since: nil
    )
    expect(previous_workflow.reload).to have_attributes(
      state: "failed",
      failure_reason: GraderLoopProgress::NO_PROGRESS_REASON
    )
    expect(previous_workflow.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY)).to eq(stop_artifact)
  end

  it "preserves an unrelated attention reason when a queued workflow starts" do
    attention_since = 1.hour.ago
    job.update!(
      needs_attention: true,
      needs_attention_reason: "agent_cannot_proceed",
      needs_attention_since: attention_since
    )
    current_workflow = Workflow.create!(job: job, trigger_kind: "initial")

    current_workflow.start!

    expect(job.reload).to have_attributes(
      needs_attention: true,
      needs_attention_reason: "agent_cannot_proceed"
    )
    expect(job.needs_attention_since).to be_within(1.second).of(attention_since)
  end

  it "clears stale grader-loop attention for infrastructure workflows without changing Job state" do
    job.update_columns(state: "implemented")
    mark_job_for_grader_loop_attention!
    current_workflow = Workflow.create!(job: job, trigger_kind: "main_grader")

    current_workflow.start!

    expect(job.reload).to have_attributes(
      state: "implemented",
      needs_attention: false,
      needs_attention_reason: nil,
      needs_attention_since: nil
    )
  end

  it "allows the current workflow grader loop to set no-progress attention again" do
    mark_job_for_grader_loop_attention!
    current_workflow = Workflow.create!(job: job, trigger_kind: "initial")
    current_workflow.start!
    current_workflow.set_artifact!(GraderLoopProgress::ARTIFACT_KEY, [
      {
        "loop_id" => "grade-loop",
        "iteration" => 1,
        "failing_set" => [ "spec/models/widget_spec.rb" ],
        "failing_set_digest" => Digest::SHA256.hexdigest("spec/models/widget_spec.rb"),
        "transient_only" => false
      }
    ])
    collect_step = current_workflow.steps.create!(
      kind: "grader_collect",
      position: 1,
      iteration: 2,
      loop_id: "grade-loop"
    )
    grader = current_workflow.steps.create!(
      kind: "grader",
      position: 0,
      iteration: 2,
      loop_id: "grade-loop",
      state: "failed",
      details: { "name" => "rspec", "required" => true }
    )
    run = grader.runs.create!(job: job, trigger_kind: current_workflow.trigger_kind, state: "failed")
    allow(TestEvidenceLookup).to receive(:failed_test_cases_for).with(run, "rspec").and_return([
      { "identity" => "spec/models/widget_spec.rb" }
    ])

    result = GraderLoopProgress.record_failure!(workflow: current_workflow, collect_step: collect_step)

    expect(result).to be_stop
    expect(job.reload).to have_attributes(
      needs_attention: true,
      needs_attention_reason: GraderLoopProgress::NO_PROGRESS_REASON
    )
    expect(job.needs_attention_since).to be_present
    expect(current_workflow.reload.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY)).to include(
      "reason" => GraderLoopProgress::NO_PROGRESS_REASON
    )
  end

  it "does not clear attention for a terminal WorkUnit synchronization" do
    mark_job_for_grader_loop_attention!
    current_workflow = Workflow.create!(job: job, trigger_kind: "initial")
    current_workflow.syncing_from_terminal_work_unit = true

    current_workflow.start!

    expect(job.reload.needs_attention_reason).to eq(GraderLoopProgress::NO_PROGRESS_REASON)
  end
end
