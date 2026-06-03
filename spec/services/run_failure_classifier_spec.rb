require "rails_helper"

RSpec.describe RunFailureClassifier do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  def classification
    described_class.persist!(run.reload)
  end

  def diagnostic(error_class, message)
    run.create_run_diagnostic!(error_class: error_class, error_message: message)
  end

  def process(outcome)
    SpawnedProcess.create!(
      run: run,
      workflow: run.workflow,
      kind: "agent",
      command: "agent",
      hostname: "worker-1",
      started_at: 5.minutes.ago,
      finished_at: 4.minutes.ago,
      outcome: outcome
    )
  end

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
    diagnostic("Timeout::Error", "execution expired while pushing")

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

  it "classifies Claude transient provider failures from result text" do
    run.update!(state: "failed", agent_provider: "claude", agent_summary: "Claude is overloaded, please retry later.")

    expect(classification.classification).to eq("provider_transient")
    expect(classification.retryable).to eq(true)
  end

  it "classifies Codex auth/config failures from final payload text" do
    run.update!(state: "failed", agent_provider: "codex", agent_outcome: "turn_failed", agent_summary: "CODEX_API_KEY is invalid or not configured.")

    expect(classification.classification).to eq("provider_auth_or_config")
  end

  it "classifies rate limits from structured JobLog rows" do
    run.update!(state: "failed")
    JobLog.append!(run: run, chunk: "Provider paused this request", kind: "rate_limited")

    expect(classification.classification).to eq("rate_limited")
  end

  it "classifies process timeouts from SpawnedProcess outcome" do
    run.update!(state: "failed")
    process("silent_timed_out")

    expect(classification.classification).to eq("timeout")
  end

  it "classifies worker and agent process death" do
    run.update!(state: "failed", agent_outcome: "worker_died")
    process("orphaned")

    expect(classification.classification).to eq("worker_died")
  end

  it "classifies git-state failures" do
    run.update!(state: "failed", agent_outcome: "git_state_corrupt")
    diagnostic("Steps::Base::AgentBrokeGitState", "branch has no common ancestor with origin/main")

    expect(classification.classification).to eq("git_state_corrupt")
  end

  it "classifies validation and user-input failures" do
    run.update!(state: "failed")
    diagnostic("ActiveRecord::RecordInvalid", "Validation failed: Prompt cannot be blank")

    expect(classification.classification).to eq("validation_or_user_error")
  end

  it "classifies unmatched application exceptions as application errors" do
    run.update!(state: "failed")
    diagnostic("NoMethodError", "undefined method `call' for nil")

    expect(classification.classification).to eq("application_error")
  end
end
