require "rails_helper"

RSpec.describe EmergencyLand::Permission do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) -- create the admin first so the
  # other lets are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:other_user) { admin && Factories.user }
  let(:reader) { admin && Factories.user }
  let(:writer) { admin && Factories.user }
  let(:promoted_admin) { admin && Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before do
    RepositoryMembership.create!(repository: repository, user: reader, role: "read")
    RepositoryMembership.create!(repository: repository, user: writer, role: "write")
    RepositoryMembership.create!(repository: repository, user: promoted_admin, role: "admin")
  end

  it "grants the FK repository owner (auto-seeded with an admin-tier membership)" do
    expect(described_class.granted?(user: owner, repository: repository)).to eq(true)
  end

  it "grants another admin-tier member" do
    expect(described_class.granted?(user: promoted_admin, repository: repository)).to eq(true)
  end

  it "grants a global admin regardless of membership" do
    expect(described_class.granted?(user: admin, repository: repository)).to eq(true)
  end

  it "refuses a write-tier member" do
    expect(described_class.granted?(user: writer, repository: repository)).to eq(false)
  end

  it "refuses a read-tier member" do
    expect(described_class.granted?(user: reader, repository: repository)).to eq(false)
  end

  it "refuses a user with no membership at all" do
    expect(described_class.granted?(user: other_user, repository: repository)).to eq(false)
  end
end
