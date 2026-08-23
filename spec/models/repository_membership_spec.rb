require "rails_helper"

RSpec.describe RepositoryMembership do
  let(:repo_owner) { Factories.user }
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: repo_owner) }

  it "accepts a valid role" do
    membership = repo.repository_memberships.build(user: user, role: "read")
    expect(membership).to be_valid
  end

  it "rejects an unknown role" do
    membership = repo.repository_memberships.build(user: user, role: "owner")
    expect(membership).not_to be_valid
    expect(membership.errors[:role]).to be_present
  end

  describe "installation association" do
    it "can link to an installation" do
      installation = Factories.installation(user: user)
      membership = repo.repository_memberships.create!(user: user, role: "read", installation: installation)
      expect(membership.installation).to eq(installation)
    end

    it "allows a nil installation" do
      membership = repo.repository_memberships.build(user: user, role: "read", installation: nil)
      expect(membership).to be_valid
    end

    it "nullifies installation_id when the installation is destroyed" do
      installation = Factories.installation(user: user)
      membership = repo.repository_memberships.create!(user: user, role: "read", installation: installation)
      installation.destroy!
      expect(membership.reload.installation_id).to be_nil
    end
  end

  describe "agent_provider" do
    it "allows a valid agent provider" do
      membership = repo.repository_memberships.build(user: user, role: "read", agent_provider: "claude")
      expect(membership).to be_valid
    end

    it "rejects an unknown agent provider" do
      membership = repo.repository_memberships.build(user: user, role: "read", agent_provider: "oracle")
      expect(membership).not_to be_valid
      expect(membership.errors[:agent_provider]).to be_present
    end

    it "normalizes blank agent_provider to nil" do
      membership = repo.repository_memberships.create!(user: user, role: "read", agent_provider: "")
      expect(membership.agent_provider).to be_nil
    end

    it "allows a nil agent_provider" do
      membership = repo.repository_memberships.build(user: user, role: "read", agent_provider: nil)
      expect(membership).to be_valid
    end
  end

  describe "#at_least?" do
    it "is true for the exact tier" do
      expect(repo.repository_memberships.build(role: "write").at_least?("write")).to be true
    end

    it "is true for a lower tier threshold" do
      expect(repo.repository_memberships.build(role: "write").at_least?("read")).to be true
    end

    it "is false for a higher tier threshold" do
      expect(repo.repository_memberships.build(role: "write").at_least?("admin")).to be false
    end
  end

  describe ".at_least" do
    it "matches memberships at or above the given tier" do
      reader = repo.repository_memberships.create!(user: Factories.user, role: "read")
      writer = repo.repository_memberships.create!(user: Factories.user, role: "write")
      admin_member = repo.repository_memberships.create!(user: Factories.user, role: "admin")

      expect(repo.repository_memberships.at_least("write").where.not(user: repo_owner)).to contain_exactly(writer, admin_member)
      expect(repo.repository_memberships.at_least("admin").where.not(user: repo_owner)).to contain_exactly(admin_member)
      expect(repo.repository_memberships.at_least("read")).to include(reader, writer, admin_member)
    end
  end
end
