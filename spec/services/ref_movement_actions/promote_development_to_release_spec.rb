require "rails_helper"

RSpec.describe RefMovementActions::PromoteDevelopmentToRelease do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:policy) do
    instance_double(DeliveryPolicy, promotion_enabled?: true, promotion_mode: "manual_pr", promotion_source_branch: "develop", promotion_target_branch: "main")
  end

  before do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(policy)
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "is unavailable when promotion is disabled" do
    allow(policy).to receive(:promotion_enabled?).and_return(false)

    expect(described_class.new.available?(repository: repository)).to eq([ false, "promotion is not enabled" ])
  end

  it "defaults refs from DeliveryPolicy and creates the workflow and audit record" do
    record = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release")

    expect(record).to be_dispatched
    expect(record.source_ref).to eq("develop")
    expect(record.target_ref).to eq("main")
    expect(record.target_inferred).to be(true)
    expect(record.workflow.trigger_kind).to eq("promotion")
  end

  it "accepts explicit source and target overrides" do
    record = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release", source: "next", target: "release")

    expect(record.source_ref).to eq("next")
    expect(record.target_ref).to eq("release")
    expect(record.target_inferred).to be(false)
  end

  it "blocks a second dispatch and identifies the in-flight workflow" do
    first = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release")
    second = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release")

    expect(second).to be_blocked
    expect(second.blocked_reason).to eq("promotion workflow #{first.workflow_id} is already queued")
  end
end
