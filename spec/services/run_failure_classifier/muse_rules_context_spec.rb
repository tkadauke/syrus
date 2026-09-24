require "rails_helper"

RSpec.describe "RunFailureClassifier Muse rules context" do
  it "classifies oversized Muse workspace rules as non-retryable" do
    job = Factories.job
    run = job.initial_run
    run.update!(state: "failed", agent_provider: "codex", agent_outcome: "muse_rules_context_too_large")

    result = RunFailureClassifier.persist!(run.reload)

    expect(result.classification).to eq("muse_rules_context_too_large")
    expect(result.retryable).to eq(false)
  end
end
