require "rails_helper"

RSpec.describe RefMovementActionsSummary do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:config) { SyrusYml::DeliveryRefMovementAction.new(name: "send_job_upstream", enabled: true, source: nil, target: nil, mode: "manual_pr", grade_phases: []) }

  it "returns an empty array when the repository has no ref_movement_actions configured" do
    expect(described_class.for(repository: repository)).to eq([])
  end

  it "reports an enabled, available action" do
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_actions).and_return({ "send_job_upstream" => config })
    allow(RefMovementActions::Base).to receive(:for).with("send_job_upstream").and_return(
      instance_double(RefMovementActions::SendJobUpstream, available?: [ true, nil ])
    )

    expect(described_class.for(repository: repository)).to contain_exactly(
      a_hash_including(name: "send_job_upstream", enabled: true, mode: "manual_pr", available: true, blocked_reason: nil)
    )
  end

  it "reports a blocked reason for an enabled but unavailable action" do
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_actions).and_return({ "send_job_upstream" => config })
    allow(RefMovementActions::Base).to receive(:for).with("send_job_upstream").and_return(
      instance_double(RefMovementActions::SendJobUpstream, available?: [ false, "job is required for send_job_upstream" ])
    )

    expect(described_class.for(repository: repository)).to contain_exactly(
      a_hash_including(name: "send_job_upstream", available: false, blocked_reason: "job is required for send_job_upstream")
    )
  end

  it "reports a disabled action as unavailable without calling .available?" do
    disabled_config = config.with(enabled: false)
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_actions).and_return({ "send_job_upstream" => disabled_config })
    allow(RefMovementActions::Base).to receive(:for).with("send_job_upstream").and_return(
      instance_double(RefMovementActions::SendJobUpstream, available?: [ true, nil ])
    )

    expect(described_class.for(repository: repository)).to contain_exactly(
      a_hash_including(name: "send_job_upstream", enabled: false, available: false, blocked_reason: "not enabled in delivery.ref_movement_actions")
    )
  end
end
