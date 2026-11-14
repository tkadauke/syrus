require "rails_helper"

RSpec.describe ReviewEvidence do
  let(:job) { Factories.job }
  let(:run) { job.latest_workflow.steps.find_by!(kind: "implement").runs.create!(job: job, trigger_kind: "initial") }

  def evidence_attributes
    {
      run: run, workflow: run.workflow, step: run.step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    }
  end

  it "enforces one immutable evidence record per Run" do
    evidence = described_class.create!(evidence_attributes)

    evidence.reviewed_head_sha = "e" * 40

    expect(evidence).not_to be_valid
    expect(evidence.errors[:base]).to include(/provenance is immutable/)
    expect { described_class.create!(evidence_attributes) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "never permits stale evidence to become current again" do
    evidence = described_class.create!(evidence_attributes)
    evidence.mark_stale!(code: "review_evidence_mismatch", details: { current_head_sha: "new" })

    evidence.state = "pending"

    expect(evidence).not_to be_valid
    expect(evidence.errors[:state]).to include("cannot leave stale")
  end

  it "allows rereview only through a fresh Run and fresh evidence" do
    stale = described_class.create!(evidence_attributes)
    stale.mark_stale!(code: "review_evidence_mismatch")
    rereview_run = run.step.runs.create!(job: job, trigger_kind: "initial")

    fresh = described_class.create!(
      evidence_attributes.merge(
        run: rereview_run,
        reviewed_head_sha: "e" * 40,
        canonical_diff_sha256: "f" * 64
      )
    )

    expect(stale.reload.state).to eq("stale")
    expect(fresh).to have_attributes(state: "pending", run_id: rereview_run.id)
  end

  it "records context and persistence envelopes once without retaining restricted text" do
    evidence = described_class.create!(evidence_attributes)

    evidence.record_context!("owner" => "example", "type" => "review_context", "manifest" => { "sha256" => "safe" })
    evidence.record_persistence!("owner" => "example", "type" => "memory", "key" => "receipt-1", "version" => 1)

    expect(evidence.reload).to have_attributes(
      context_envelope: include("manifest" => { "sha256" => "safe" }),
      persistence_envelope: include("key" => "receipt-1")
    )
    expect {
      evidence.record_context!("owner" => "example", "type" => "review_context", "manifest" => { "sha256" => "changed" })
    }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "does not replace an empty recorded envelope" do
    evidence = described_class.create!(evidence_attributes)
    evidence.record_context!({})

    expect {
      evidence.record_context!("owner" => "example", "type" => "review_context")
    }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
