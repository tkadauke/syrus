require "rails_helper"

RSpec.describe ReviewEvidence::VerdictSubmission do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.find_by!(kind: "implement") }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "codex", model: "m") }
  let(:target) { { "type" => "coworker", "reference" => "7", "display" => { "name" => "Maya" } } }
  let(:receipt) { { "owner" => "coworkers", "type" => "review_memory", "key" => "1", "version" => 1 } }
  let!(:evidence) do
    ReviewEvidence.create!(
      run: run, workflow: workflow, step: step, review_kind: "coworker", provider: "codex", model: "m",
      reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1", target: target
    )
  end

  before do
    allow(ReviewEvidence::VerifySubmission).to receive(:call!)
    allow(ReviewContextContributions).to receive(:persist).and_return(receipt)
  end

  def submit
    described_class.call!(run: run, artifact_key: "coworker_review_iterations", review_kind: "coworker",
                          critique: "Fine.", verdict: "approved", key_learning: "Stay small.")
  end

  it "stores the receipt and manifest on the evidence envelope from the opaque target" do
    evidence.record_context_manifest!("protected_prompt" => { "sha256" => "safe" })

    submit
    entry = workflow.reload.artifact("coworker_review_iterations").sole

    expect(ReviewContextContributions).to have_received(:persist).with(hash_including(target: target))
    expect(evidence.reload.persistence_receipt).to eq(receipt)
    expect(entry).to include("review_context_manifest" => { "protected_prompt" => { "sha256" => "safe" } },
                             "persistence_receipt" => receipt)
    expect(entry["reviewer"]).to include("type" => "coworker", "reference" => "7")
  end

  it "does not repeat the plugin update on retry once a receipt exists" do
    evidence.record_persistence_receipt!(receipt)

    submit

    expect(ReviewContextContributions).not_to have_received(:persist)
  end

  it "still records the verdict when the owning plugin is absent" do
    allow(ReviewContextContributions).to receive(:persist).and_raise(ReviewContextContributions::Unavailable)

    submit
    expect(workflow.reload.artifact("coworker_review_iterations").sole).to include("verdict" => "approved")
    expect(evidence.reload.persistence_receipt).to be_nil
  end

  it "recovers the receipt on resubmission after a transient plugin outage without duplicating the verdict" do
    allow(ReviewContextContributions).to receive(:persist).and_raise(ReviewContextContributions::Unavailable)
    submit
    expect(evidence.reload.persistence_receipt).to be_nil

    allow(ReviewContextContributions).to receive(:persist).and_return(receipt)
    submit

    entries = workflow.reload.artifact("coworker_review_iterations")
    expect(entries.size).to eq(1)
    expect(entries.sole).to include("persistence_receipt" => receipt, "memory_persistence" => { "state" => "persisted" })
    expect(evidence.reload.persistence_receipt).to eq(receipt)
    expect(run.step.reload.details["review_persistence_receipt"]).to eq(receipt)
  end

  it "recovers using the recorded verdict and learning, ignoring conflicting resubmitted values" do
    allow(ReviewContextContributions).to receive(:persist).and_raise(ReviewContextContributions::Unavailable)
    submit
    allow(ReviewContextContributions).to receive(:persist).and_return(receipt)

    described_class.call!(run: run, artifact_key: "coworker_review_iterations", review_kind: "coworker",
                          critique: "Different.", verdict: "needs_work", key_learning: "Tampered.")

    expect(ReviewContextContributions).to have_received(:persist)
      .with(hash_including(verdict: "approved", update: { "key_learning" => "Stay small." })).twice
    expect(ReviewContextContributions).not_to have_received(:persist).with(hash_including(verdict: "needs_work"))
    expect(workflow.reload.artifact("coworker_review_iterations").sole)
      .to include("verdict" => "approved", "critique" => "Fine.")
  end
end
