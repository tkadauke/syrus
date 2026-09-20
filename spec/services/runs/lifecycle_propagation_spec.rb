require "rails_helper"

RSpec.describe Runs::LifecyclePropagation, :ci_only do
  it "clears stale failure evidence when a run is later reconciled to succeeded" do
    job = Factories.job
    run = job.initial_run
    run.update!(state: "succeeded", finished_at: Time.current)
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "grader failed")
    run.create_run_failure_classification!(
      classification: "worker_died_under_resource_pressure",
      confidence: 0.95,
      retryable: true,
      reason: "stale",
      classified_at: Time.current
    )

    described_class.succeeded!(run.reload)

    expect(run.reload.run_diagnostic).to be_nil
    expect(run.run_failure_classification).to be_nil
  end
end
