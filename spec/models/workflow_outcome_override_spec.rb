require "rails_helper"

RSpec.describe WorkflowOutcomeOverride do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.find_by!(kind: "implement") }
  let(:actor) { job.user }

  def attributes(overrides = {})
    {
      job:, workflow:, step:, actor:,
      gate_kind: "implementation_grader", gate_identity: "rspec",
      candidate_head_sha: "a" * 40, candidate_tree_sha: "b" * 40,
      candidate_base_sha: "c" * 40, plan_version: "plan-v1",
      evidence_digest: "d" * 64, channel: "agent", reason: "Known grader defect",
      permission_decision: { "policy" => "allow", "decisive_rule_id" => 7 }
    }.merge(overrides)
  end

  def failure(overrides = {})
    { outcome: "failed", technically_overridable: true, structural: false,
      gate_identity: "rspec", evidence_digest: "d" * 64 }.merge(overrides)
  end

  def record(**overrides)
    described_class.record!(gate_failure: failure, **attributes(overrides))
  end

  it "preserves failed evidence while exposing the effective overridden state" do
    override = record

    expect(override).to have_attributes(original_outcome: "failed", effective_state: "failed, overridden")
    expect(override.fingerprint_digest).to eq(override.fingerprint.digest)
  end

  it "requires an actor, channel, permission decision, and nonblank reason" do
    override = described_class.new(attributes(reason: "", permission_decision: {}, actor: nil).merge(
      gate_failure: failure, original_outcome: "failed"
    ))

    expect(override).not_to be_valid
    expect(override.errors.attribute_names).to include(:actor, :reason, :permission_decision)
  end

  it "fails closed for unregistered and structurally non-overridable failures" do
    unregistered = described_class.new(attributes(gate_kind: "unknown").merge(
      gate_failure: failure, original_outcome: "failed"
    ))
    structural = described_class.new(attributes.merge(
      gate_failure: failure(structural: true), original_outcome: "failed"
    ))

    expect(unregistered).not_to be_valid
    expect(structural).not_to be_valid
    expect(structural.errors[:base]).to include("gate failure is not technically overridable")
  end

  it "requires a plan or prompt version and binds the record to the failure evidence" do
    missing_version = described_class.new(attributes(plan_version: nil).merge(
      gate_failure: failure, original_outcome: "failed"
    ))
    mismatched = described_class.new(attributes.merge(
      gate_failure: failure(evidence_digest: "e" * 64), original_outcome: "failed"
    ))

    expect(missing_version).not_to be_valid
    expect(missing_version.errors[:base]).to include("a plan or prompt version is required")
    expect(mismatched).not_to be_valid
    expect(mismatched.errors[:evidence_digest]).to include("does not match the gate failure")
  end

  it "consumes once idempotently only for the exact candidate and evidence fingerprint" do
    override = record
    consumed_at = Time.zone.parse("2026-11-25 12:00:00")
    allow(WorkflowOutcomeOverrides::Telemetry).to receive(:record_consumed)

    override.consume!(override.fingerprint, at: consumed_at)
    override.consume!(override.fingerprint, at: consumed_at + 1.hour)

    expect(override.reload.consumed_at).to eq(consumed_at)
    expect(WorkflowOutcomeOverrides::Telemetry).to have_received(:record_consumed).with(override).once
    stale = override.fingerprint.to_h.merge(candidate_head_sha: "e" * 40)
    expect { override.consume!(stale) }.to raise_error(ActiveRecord::RecordInvalid, /fingerprint does not match/)
  end

  it "keeps claims append-only while allowing one terminal invalidation" do
    override = record
    override.invalidate!("candidate_advanced")
    override.invalidate!("candidate_advanced")

    expect(override.reload.invalidation_cause).to eq("candidate_advanced")
    expect { override.update!(reason: "changed") }.to raise_error(ActiveRecord::RecordInvalid, /claims are immutable/)
    override.reload
    expect { override.consume!(override.fingerprint) }.to raise_error(ActiveRecord::RecordInvalid, /invalidated/)
    expect { override.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects setting both terminal lifecycle states at once" do
    override = record

    expect {
      override.update!(consumed_at: Time.current, invalidation_cause: "candidate_advanced")
    }.to raise_error(ActiveRecord::RecordInvalid, /both consumed and invalidated/)
  end

  it "does not allow a consumed override to be invalidated" do
    override = record
    override.consume!(override.fingerprint)

    expect { override.invalidate!("candidate_advanced") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects lineage that does not match the bound Job and Workflow" do
    other_job = Factories.job
    override = described_class.new(attributes(workflow: other_job.latest_workflow).merge(
      gate_failure: failure, original_outcome: "failed"
    ))

    expect(override).not_to be_valid
    expect(override.errors[:workflow]).to include("must belong to the override Job")
  end
end
