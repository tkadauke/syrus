require "rails_helper"

RSpec.describe Handle do
  it "enforces case-insensitive uniqueness in the database" do
    first = Factories.user
    second = Factories.user
    HandleRegistry.release!(owner: first)
    HandleRegistry.release!(owner: second)
    described_class.create!(handle: "alice", owner: first)

    expect {
      described_class.insert!({ handle: "ALICE", owner_type: "User", owner_id: second.id, created_at: Time.current })
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects invalid handles" do
    owner = Factories.user
    HandleRegistry.release!(owner: owner)
    handle = described_class.new(handle: "no spaces", owner: owner)

    expect(handle).not_to be_valid
    expect(handle.errors[:handle]).to be_present
  end
end
