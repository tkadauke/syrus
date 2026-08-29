require "rails_helper"

RSpec.describe DesignDocVersion, type: :model do
  let(:owner) { Factories.user }
  let(:doc) { DesignDoc.create!(owner_user: owner, title: "Versioned", markdown: "v1") }

  it "requires monotonically unique version numbers per design doc" do
    described_class.create!(design_doc: doc, markdown: "v1", version_number: 1, actor_kind: "user", actor_user: owner)
    duplicate = described_class.new(design_doc: doc, markdown: "v1 again", version_number: 1, actor_kind: "user", actor_user: owner)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:version_number]).to be_present
  end

  it "requires a user record for user-authored versions but permits agent provenance" do
    user_version = described_class.new(design_doc: doc, markdown: "v2", version_number: 2, actor_kind: "user")
    agent_version = described_class.new(design_doc: doc, markdown: "v2", version_number: 2, actor_kind: "agent")

    expect(user_version).not_to be_valid
    expect(user_version.errors[:actor_user]).to be_present
    expect(agent_version).to be_valid
  end

  it "is append-only after creation" do
    version = described_class.create!(design_doc: doc, markdown: "v1", version_number: 1, actor_kind: "user", actor_user: owner)

    expect {
      version.update!(markdown: "edited")
    }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
  end
end
