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

  it "records usage evidence from structured outcome and run model, not diagnostic prose extraction" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: ProviderUsageLimit::OUTCOME,
      model: "gpt-5.5",
      step: nil,
      finished_at: Time.current
    )
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "provider usage limit exhausted for model for")

    described_class.failed!(run.reload)

    evidence = ProviderAvailabilityEvidence.find_by!(run: run, status: "exhausted")
    expect(evidence.model).to eq("gpt-5.5")
  end

  # Without this evidence the fault is invisible to availability, so nothing
  # marks the provider unusable and routing keeps sending work into a refusal
  # it cannot recover from. The evidence row is the whole failover trigger.
  it "records refused-model evidence so availability can fail the provider over" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: ProviderModelUnsupported::OUTCOME,
      model: "gpt-5.5",
      step: nil,
      finished_at: Time.current
    )
    run.create_run_diagnostic!(
      error_class: "Steps::Base::StepFailed",
      error_message: "The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account."
    )

    described_class.failed!(run.reload)

    evidence = ProviderAvailabilityEvidence.find_by!(run: run, status: "model_unsupported")
    expect(evidence.model).to eq("gpt-5.5")
    expect(evidence.source).to eq("codex_invocation_model_unsupported")
  end

  it "records refused-model evidence from the classification alone" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(state: "failed", agent_provider: "codex", agent_outcome: "turn_failed", step: nil, finished_at: Time.current)
    record = run.run_failure_classification || run.build_run_failure_classification
    record.update!(
      classification: ProviderModelUnsupported::CLASSIFICATION,
      confidence: 0.95,
      retryable: false,
      reason: "provider refused the requested model",
      classified_at: Time.current
    )
    run.create_run_diagnostic!(
      error_class: "Steps::Base::StepFailed",
      error_message: "The 'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account."
    )

    described_class.failed!(run.reload)

    expect(ProviderAvailabilityEvidence.find_by!(run: run, status: "model_unsupported").model).to eq("gpt-5.2-codex")
  end

  it "does not record refused-model evidence for an ordinary agent failure" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(state: "failed", agent_provider: "codex", agent_outcome: "turn_failed", step: nil, finished_at: Time.current)
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "the grader failed")

    described_class.failed!(run.reload)

    expect(ProviderAvailabilityEvidence.where(run: run, status: "model_unsupported")).to be_empty
  end

  it "does not record usage evidence from generic billing prose without structured provider outcome" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "turn_failed",
      step: nil,
      finished_at: Time.current
    )
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "PR body mentions billing copy")

    described_class.failed!(run.reload)

    expect(ProviderAvailabilityEvidence.where(run: run, status: "exhausted")).to be_empty
  end

  it "does not turn ordinary agent log billing words into exhausted provider evidence" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "turn_failed",
      step: nil,
      finished_at: Time.current
    )
    JobLog.append!(
      run: run,
      chunk: "Feature spec failed: customer quota is exhausted on the billing plan screen.",
      kind: "agent_log"
    )

    described_class.failed!(run.reload)

    expect(run.reload.run_failure_classification.classification).not_to eq("provider_usage_limit")
    expect(ProviderAvailabilityEvidence.where(run: run, status: "exhausted")).to be_empty
  end

  it "records rate-limit evidence from explicit provider rate-limit outcomes" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "rate_limited",
      step: nil,
      finished_at: Time.current
    )
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "provider request delayed")

    described_class.failed!(run.reload)

    evidence = ProviderAvailabilityEvidence.find_by!(run: run, status: "rate_limited")
    expect(evidence.source).to eq("codex_invocation_rate_limit")
  end

  it "does not record rate-limit evidence from diagnostic 429 prose without explicit provider outcome" do
    job = Factories.job(agent_provider: "codex")
    run = job.initial_run
    run.update!(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "turn_failed",
      step: nil,
      finished_at: Time.current
    )
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "HTTP 429 too many requests")

    described_class.failed!(run.reload)

    expect(ProviderAvailabilityEvidence.where(run: run, status: "rate_limited")).to be_empty
  end
end
