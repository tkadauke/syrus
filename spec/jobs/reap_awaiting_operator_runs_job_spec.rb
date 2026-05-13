require "rails_helper"

RSpec.describe ReapAwaitingOperatorRunsJob do
  def parked_run(created_at:)
    job = Factories.job
    workflow = job.workflows.first
    step = workflow.steps.first
    run = step.runs.first

    workflow.update_columns(state: "running", started_at: created_at)
    step.update_columns(state: "running", started_at: created_at)
    run.update_columns(
      state: "awaiting_operator",
      created_at: created_at,
      started_at: created_at,
      finished_at: nil,
      agent_outcome: nil
    )

    run
  end

  it "fails a parked run older than the timeout" do
    run = parked_run(created_at: (described_class::TIMEOUT + 1.hour).ago)

    freeze_time do
      described_class.perform_now

      expect(run.reload.state).to eq("failed")
      expect(run.agent_outcome).to eq("operator_unresponsive")
      expect(run.finished_at).to eq(Time.current)
    end
  end

  it "fails the owning step and workflow so the workspace becomes prunable" do
    run = parked_run(created_at: (described_class::TIMEOUT + 1.hour).ago)
    workflow = run.workflow
    step = run.step

    described_class.perform_now

    expect(step.reload.state).to eq("failed")
    expect(workflow.reload.state).to eq("failed")
    expect(workflow.finished_at).to be_present
  end

  it "closes the corresponding job with operator_unresponsive" do
    run = parked_run(created_at: (described_class::TIMEOUT + 1.hour).ago)

    described_class.perform_now

    expect(run.job.reload.state).to eq("closed")
    expect(run.job.closure_reason).to eq("operator_unresponsive")
  end

  it "preserves a freshly parked run" do
    run = parked_run(created_at: (described_class::TIMEOUT - 1.hour).ago)

    described_class.perform_now

    expect(run.reload.state).to eq("awaiting_operator")
    expect(run.agent_outcome).to be_nil
    expect(run.job.reload.state).to eq("open")
  end
end
