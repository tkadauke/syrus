require "rails_helper"

RSpec.describe RefMovementActions::PromoteDevelopmentToRelease do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:policy) do
    instance_double(
      DeliveryPolicy,
      promotion_enabled?: true,
      promotion_mode: "auto_pr",
      promotion_grade_phases: [ "promotion" ],
      promotion_source_branch: "develop",
      promotion_target_branch: "main"
    )
  end

  before do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(policy)
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "is unavailable when promotion is disabled" do
    allow(policy).to receive(:promotion_enabled?).and_return(false)

    available, reason = described_class.new.available?(repository: repository)

    expect(available).to be(false)
    expect(reason).to eq("promotion is not enabled")
  end

  it "defaults source and target from DeliveryPolicy and records the dispatch" do
    record = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release")

    expect(record).to be_dispatched
    expect(record.source_kind).to eq("branch")
    expect(record.source_ref).to eq("develop")
    expect(record.target_kind).to eq("release_branch")
    expect(record.target_ref).to eq("main")
    expect(record.target_repository).to eq(repository)
    expect(record.target_inferred).to be(true)
    expect(record.mode).to eq("auto_pr")
    expect(record.grade_phases).to eq([ "promotion" ])
    expect(record.workflow.trigger_kind).to eq("promotion")
    expect(record.job).to eq(record.workflow.job)
  end

  it "accepts explicit source and target overrides" do
    record = RefMovementAction.dispatch!(
      repository: repository,
      actor: user,
      action: "promote_development_to_release",
      source: "release/candidate",
      target: "stable"
    )

    expect(record.source_ref).to eq("release/candidate")
    expect(record.target_ref).to eq("stable")
    expect(record.target_inferred).to be(false)
    expect(record.workflow.artifact("promotion_source_branch")).to eq("release/candidate")
    expect(record.workflow.artifact("promotion_target_branch")).to eq("stable")
  end

  %w[queued running].each do |state|
    it "blocks a second dispatch while promotion workflow is #{state}" do
      pending_job = Factories.job_record(user: user, repository: repository)
      workflow = Workflow.create!(job: pending_job, trigger_kind: "promotion", state: state)

      record = RefMovementAction.dispatch!(repository: repository, actor: user, action: "promote_development_to_release")

      expect(record).to be_blocked
      expect(record.blocked_reason).to eq("promotion workflow #{workflow.id} is already #{state}")
      expect(record.workflow).to be_nil
      expect(record.job).to be_nil
    end
  end
end
