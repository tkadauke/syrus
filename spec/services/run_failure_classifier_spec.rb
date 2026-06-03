require "rails_helper"

RSpec.describe RunFailureClassifier do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  it "persists a retryable worker_died classification when a run fails without a diagnostic" do
    run.update!(state: "running", agent_outcome: "worker_died")

    expect {
      run.fail!
      run.save!
    }.to change { RunFailureClassification.count }.by(1)

    classification = run.reload.run_failure_classification
    expect(classification.classification).to eq("worker_died")
    expect(classification.retryable).to eq(true)
    expect(classification.classifier_inputs).to include(
      "run_id" => run.id,
      "agent_outcome" => "worker_died"
    )
  end

  it "uses captured diagnostics when classifying exception failures" do
    run.create_run_diagnostic!(
      error_class: "Timeout::Error",
      error_message: "execution expired while pushing"
    )

    classification = described_class.persist!(run)

    expect(classification.classification).to eq("timeout")
    expect(classification.retryable).to eq(true)
    expect(classification.reason).to include("timed out")
    expect(classification.diagnostic_summary).to include("Timeout::Error")
  end

  it "leaves historical failed runs backward compatible when no classification exists" do
    run.update_columns(state: "failed", finished_at: Time.current)

    expect(run.reload.run_failure_classification).to be_nil
  end
end
