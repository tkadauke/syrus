require "rails_helper"

RSpec.describe AutoRetryFailureClassifier do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def fail_run!(agent_outcome: nil, error_class: nil, error_message: nil)
    run.update!(state: "failed", agent_outcome: agent_outcome, finished_at: Time.current)
    step.update!(state: "failed", finished_at: Time.current)
    workflow.update!(state: "failed", finished_at: Time.current)
    run.create_run_diagnostic!(error_class: error_class, error_message: error_message) if error_class
  end

  it "classifies worker death as retryable" do
    fail_run!(agent_outcome: "worker_died")

    result = described_class.call(workflow: workflow)

    expect(result).to be_retryable
    expect(result.classification).to eq("worker_died")
  end

  it "classifies max-turn failures as non-retryable" do
    fail_run!(agent_outcome: "error_max_turns")

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_retryable
    expect(result.reason).to eq("agent exhausted max turns")
  end

  it "does not retry known code/config failures from diagnostics" do
    fail_run!(error_class: "Steps::Base::StepFailed", error_message: "agent produced no changes")

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_retryable
    expect(result.classification).to eq("non_retryable_failure")
  end

  it "classifies timeout diagnostics as retryable" do
    fail_run!(error_class: "Timeout::Error", error_message: "execution expired")

    result = described_class.call(workflow: workflow)

    expect(result).to be_retryable
    expect(result.classification).to eq("Timeout::Error")
  end
end
