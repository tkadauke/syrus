require "rails_helper"

RSpec.describe RepositoryExecutionProbe do
  it "atomically keeps one in-flight probe and releases the slot at terminal state" do
    user = Factories.user
    repository = Factories.repository(user:)

    first = described_class.claim!(repository:, requested_by: user)
    duplicate = described_class.claim!(repository:, requested_by: user)

    expect(first.created).to be(true)
    expect(duplicate.created).to be(false)
    expect(duplicate.probe).to eq(first.probe)
    expect do
      described_class.create!(repository:, requested_by: user, result: {})
    end.to raise_error(ActiveRecord::RecordNotUnique)

    first.probe.update!(status: "succeeded")
    retry_claim = described_class.claim!(repository:, requested_by: user)
    expect(retry_claim.created).to be(true)
    expect(retry_claim.probe).not_to eq(first.probe)
  end
end
