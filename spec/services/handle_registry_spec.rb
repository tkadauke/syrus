require "rails_helper"

RSpec.describe HandleRegistry do
  it "claims, renames, and releases a handle" do
    owner = Factories.user
    described_class.release!(owner: owner)

    expect(described_class.claim!(handle: "new_name", owner: owner).handle).to eq("new_name")
    expect(described_class.rename!(owner: owner, handle: "renamed").handle).to eq("renamed")
    expect { described_class.release!(owner: owner) }.to change(Handle, :count).by(-1)
  end

  it "rejects reserved handles" do
    Handle.find_or_create_by!(handle: "syrus")
    owner = Factories.user
    described_class.release!(owner: owner)

    expect {
      described_class.claim!(handle: "SYRUS", owner: owner)
    }.to raise_error(ActiveRecord::RecordInvalid, /Handle has already been taken/)
  end

  it "adds a numeric suffix when the generated handle is already claimed" do
    first = Factories.user(email_address: "same@example.com")
    second = Factories.user(email_address: "same@elsewhere.example")

    expect(first.handle).to eq("same")
    expect(second.handle).to eq("same-2")
  end

  it "recovers when another claim wins after validation" do
    owner = Factories.user
    described_class.release!(owner: owner)
    calls = 0
    allow(Handle).to receive(:create!).and_wrap_original do |method, **attributes|
      calls += 1
      raise ActiveRecord::RecordNotUnique if calls == 1

      method.call(**attributes)
    end

    expect(described_class.claim_generated!(owner: owner, source: "racer").handle).to eq("racer-2")
  end

  it "returns the winning handle when the same owner is claimed concurrently" do
    owner = Factories.user
    described_class.release!(owner: owner)
    original_create = Handle.method(:create!)
    allow(Handle).to receive(:create!) do |**attributes|
      original_create.call(handle: "winner", owner: owner)
      raise ActiveRecord::RecordNotUnique
    end

    expect(described_class.claim_generated!(owner: owner, source: "racer").handle).to eq("winner")
    expect(Handle).to have_received(:create!).once
  end
end
