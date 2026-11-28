require "rails_helper"

RSpec.describe Syrus::Host::PermissionAuthorization do
  let(:owner) { Factories.user }
  let(:descriptor) { instance_double(Permissions::CapabilityDescriptor) }
  let(:management) { instance_double(Permissions::Management) }
  let(:decision) { instance_double(Permissions::PolicyEvaluator::Decision, policy: :allow) }

  before { allow(Permissions::Management).to receive(:new).with(owner).and_return(management) }

  it "consumes authority and exposes only the effective decision and lease expiry" do
    expiry = 10.minutes.from_now
    lease = instance_double(PermissionLease, expires_at: expiry)
    authorization = Struct.new(:decision, :lease).new(decision, lease)
    allow(management).to receive(:authorize).and_return(authorization)

    result = described_class.call(owner:, descriptor:, role: "coworker", arguments: { path: "x" },
                                  context: { agent_id: 3 })

    expect(result).to be_allow
    expect(result.lease_expires_at).to eq(expiry)
    expect(management).to have_received(:authorize).with(
      descriptor:, role: "coworker", resource_scope: {}, arguments: { path: "x" }, context: { agent_id: 3 }
    )
  end

  it "can explain without consuming a lease" do
    allow(management).to receive(:authorize)
    allow(management).to receive(:explain).and_return(decision)

    result = described_class.call(owner:, descriptor:, role: "coworker", arguments: {}, context: {}, consume: false)

    expect(result).to be_allow
    expect(result.lease_expires_at).to be_nil
    expect(management).not_to have_received(:authorize)
  end
end
