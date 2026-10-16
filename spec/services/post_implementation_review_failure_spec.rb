require "rails_helper"

RSpec.describe PostImplementationReviewFailure do
  let(:job) { Factories.job_record(state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:step) { Step.create!(workflow: workflow, kind: "post_implementation_review", position: 100) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind) }

  before do
    step.start!
    step.save!
    run.start!
    run.save!
    workflow.set_artifact!("post_implementation_review_context", {
      "provider_classes" => [ "ReviewNotes::Provider" ],
      "required_mcp_tools" => [ "submit_review_notes" ]
    })
    allow(CaptureRunDiagnostic).to receive(:capture)
  end

  it "turns a missing submission tool into a visible warning and successful workflow" do
    error = Steps::Base::CannotProceed.new("submit_review_notes is unavailable")

    expect {
      described_class.record!(run: run, exception: error)
    }.to change(WorkflowWarning, :count).by(1)

    expect(run.reload).to be_skipped
    expect(step.reload).to be_skipped
    expect(workflow.reload).to be_succeeded
    expect(workflow.work_unit).not_to be_blocked if workflow.work_unit
    expect(job.reload).not_to be_needs_attention
    expect(job.state).to eq("implemented")

    warning = WorkflowWarning.last
    expect(warning).to be_pending
    expect(warning.evidence).to include(
      "reason" => "submit_review_notes is unavailable",
      "run_id" => run.id,
      "step_id" => step.id,
      "workflow_id" => workflow.id,
      "required_mcp_tools" => [ "submit_review_notes" ]
    )
  end

  it "records an ordinary review exception without blocking" do
    described_class.record!(run: run, exception: RuntimeError.new("review provider crashed"))

    expect(workflow.reload).to be_succeeded
    expect(WorkflowWarning.last.evidence).to include(
      "exception_class" => "RuntimeError",
      "reason" => "review provider crashed"
    )
  end

  it "does not classify required steps as optional" do
    required_step = Step.new(kind: "pr_open")

    expect(described_class.optional_step?(required_step)).to be(false)
  end

  it "propagates advisory completion to the owning WorkUnit" do
    implemented_job = Factories.job_record(state: "implemented", pr_number: 42)
    owned_workflow = WorkUnits::Launcher.instantiate(kind: "manual_post_implementation_review", job: implemented_job)
    prepare_step, review_step = owned_workflow.steps.to_a
    owned_workflow.start!
    owned_workflow.save!
    prepare_step.update_columns(state: "succeeded", finished_at: Time.current)
    review_step.start!
    review_step.save!
    review_run = Run.create!(job: implemented_job, step: review_step, trigger_kind: owned_workflow.trigger_kind)
    review_run.start!
    review_run.save!

    described_class.record!(run: review_run, exception: RuntimeError.new("review failed"))

    expect(owned_workflow.reload).to be_succeeded
    expect(owned_workflow.work_unit.reload).to be_succeeded
    expect(implemented_job.reload.state).to eq("implemented")
  end
end
