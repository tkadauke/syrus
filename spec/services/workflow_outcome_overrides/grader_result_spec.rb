require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::GraderResult do
  let(:user) { Factories.user }
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:grader) do
    Step.create!(
      workflow:, kind: "grader", position: 10, state: "failed",
      details: {
        "name" => "rspec", "target_label" => "//:grade/rspec", "required" => true,
        "technically_overridable" => true, "command" => "bin/rspec", "exit_code" => 1,
        "output" => "1 example, 1 failure", "log_path" => "logs/rspec.log", "log_bytes" => 24,
        "target_fingerprints" => {
          "command_fingerprint" => "command-v1", "input_fingerprint" => "input-v1",
          "environment_fingerprint" => "environment-v1"
        }
      }
    )
  end
  let(:required_plan) do
    [ { "grader_key" => "//:grade/rspec", "command_fingerprint" => "command-v1", "required" => true } ]
  end
  let(:service) do
    described_class.new(
      workflow:, grader_step: grader, candidate_head_sha: "a" * 40,
      candidate_tree_sha: "b" * 40, candidate_base_sha: "c" * 40,
      grader_plan_digest: "plan-v1", required_grader_plan: required_plan
    )
  end

  def record_override(service)
    WorkflowOutcomeOverride.record!(
      gate_failure: service.failure, job:, workflow:, step: grader, actor: user,
      gate_kind: service.gate_kind, gate_identity: service.gate_identity,
      candidate_head_sha: "a" * 40, candidate_tree_sha: "b" * 40,
      candidate_base_sha: "c" * 40, plan_version: service.plan_version,
      evidence_digest: service.evidence_digest, channel: "ui", reason: "Confirmed false positive",
      permission_decision: { "state" => "allow" }
    )
  end

  it "consumes exact grader evidence while preserving the failed result and output" do
    override = record_override(service)

    expect(service.apply!).to be(true)

    expect(grader.reload).to be_failed
    expect(grader.details).to include(
      "output" => "1 example, 1 failure",
      "outcome_override" => include("id" => override.id, "original_outcome" => "test_failed")
    )
    expect(override.reload).to be_consumed
  end

  it "does not consume an override after command/config or required-plan evidence changes" do
    override = record_override(service)
    changed = described_class.new(
      workflow:, grader_step: grader, candidate_head_sha: "a" * 40,
      candidate_tree_sha: "b" * 40, candidate_base_sha: "c" * 40,
      grader_plan_digest: "plan-v2", required_grader_plan: required_plan
    )

    expect(changed.apply!).to be(false)
    expect(override.reload).to have_attributes(consumed_at: nil, invalidation_cause: "grader_plan_changed")
  end

  it "invalidates an override when the candidate code changes" do
    override = record_override(service)
    changed = described_class.new(
      workflow:, grader_step: grader, candidate_head_sha: "d" * 40,
      candidate_tree_sha: "e" * 40, candidate_base_sha: "c" * 40,
      grader_plan_digest: "plan-v1", required_grader_plan: required_plan
    )

    expect(changed.apply!).to be(false)
    expect(override.reload.invalidation_cause).to eq("candidate_changed")
  end

  it "invalidates an override when the base changes" do
    override = record_override(service)
    changed = described_class.new(
      workflow:, grader_step: grader, candidate_head_sha: "a" * 40,
      candidate_tree_sha: "b" * 40, candidate_base_sha: "f" * 40,
      grader_plan_digest: "plan-v1", required_grader_plan: required_plan
    )

    expect(changed.apply!).to be(false)
    expect(override.reload.invalidation_cause).to eq("base_changed")
  end

  it "invalidates an override when the failed command evidence changes" do
    override = record_override(service)
    grader.update!(details: grader.details.merge("output" => "2 examples, 1 failure"))
    changed = described_class.new(
      workflow:, grader_step: grader, candidate_head_sha: "a" * 40,
      candidate_tree_sha: "b" * 40, candidate_base_sha: "c" * 40,
      grader_plan_digest: "plan-v1", required_grader_plan: required_plan
    )

    expect(changed.apply!).to be(false)
    expect(override.reload.invalidation_cause).to eq("evidence_changed")
  end

  it "uses implementation and landing gate registrations across grader workflow families" do
    expect(service.gate_kind).to eq("implementation_grader")

    %w[auto_merge merge_train landing_validation merge_train_validation external_pr_merge].each do |trigger_kind|
      workflow.update_columns(trigger_kind: trigger_kind)
      expect(service.gate_kind).to eq("landing_grader")
    end
  end

  it "classifies grader infrastructure failures as structurally non-overridable" do
    grader.update!(details: grader.details.merge("exit_code" => nil, "output" => ""))

    expect(service.failure).to include(structural: true)
    expect do
      record_override(service)
    end.to raise_error(ActiveRecord::RecordInvalid, /not technically overridable/)
  end
end
