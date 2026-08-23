require "rails_helper"

RSpec.describe RepositoryPolicy do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
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

  describe "#show?" do
    it "allows the owning user (seeded with an admin-tier membership)" do
      expect(described_class.new(owner, repository)).to be_show
    end

    it "allows another admin-tier member" do
      expect(described_class.new(promoted_admin, repository)).to be_show
    end

    it "denies a read-tier member" do
      expect(described_class.new(reader, repository)).not_to be_show
    end

    it "denies a write-tier member" do
      expect(described_class.new(writer, repository)).not_to be_show
    end

    it "denies a user with no membership" do
      expect(described_class.new(other_user, repository)).not_to be_show
    end

    it "allows a global admin regardless of membership" do
      expect(described_class.new(admin, repository)).to be_show
    end
  end

  describe "#write?" do
    it "allows a write-tier member" do
      expect(described_class.new(writer, repository)).to be_write
    end

    it "allows an admin-tier member" do
      expect(described_class.new(promoted_admin, repository)).to be_write
    end

    it "denies a read-tier member" do
      expect(described_class.new(reader, repository)).not_to be_write
    end
  end

  describe "#update? and #destroy?" do
    it "mirror #show? (both admin-tier gated)" do
      policy = described_class.new(other_user, repository)
      expect(policy.update?).to eq(policy.show?)
      expect(policy.destroy?).to eq(policy.show?)
    end
  end

  describe "team-inherited access" do
    let(:team_member) { admin && Factories.user }
    let(:team) { Team.create!(name: "Platform") }

    before do
      team.team_memberships.create!(user: team_member, role: "member")
    end

    context "with a write-tier team grant" do
      before { team.team_repositories.create!(repository: repository, role: "write") }

      it "grants #write?, mirroring a direct write-tier membership" do
        expect(described_class.new(team_member, repository)).to be_write
      end

      it "does not grant #show? (admin-tier gated)" do
        expect(described_class.new(team_member, repository)).not_to be_show
      end
    end

    context "with an admin-tier team grant" do
      before { team.team_repositories.create!(repository: repository, role: "admin") }

      it "grants #show? and #admin?" do
        expect(described_class.new(team_member, repository)).to be_show
        expect(described_class.new(team_member, repository)).to be_admin
      end
    end
  end

  describe "Scope#resolve" do
    it "returns only repositories where the user holds an admin-tier membership" do
      owned = repository
      Factories.repository(user: other_user)

      resolved = described_class::Scope.new(owner, Repository).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "includes repositories where a non-owning user was promoted to admin tier" do
      owned = repository

      resolved = described_class::Scope.new(promoted_admin, Repository).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "excludes repositories where the user only holds read or write tier" do
      repository

      expect(described_class::Scope.new(reader, Repository).resolve).to be_empty
      expect(described_class::Scope.new(writer, Repository).resolve).to be_empty
    end

    it "does not bypass for a global admin (only the per-record predicates do)" do
      repository
      foreign = Factories.repository(user: other_user)

      resolved = described_class::Scope.new(admin, Repository).resolve

      expect(resolved).not_to include(foreign)
    end

    it "includes repositories granted admin-tier through a team, alongside direct admin-tier memberships" do
      owned = repository
      team_member = other_user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: owned, role: "admin")

      resolved = described_class::Scope.new(team_member, Repository).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "excludes repositories granted only write-tier through a team" do
      repository
      team_member = other_user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: repository, role: "write")

      expect(described_class::Scope.new(team_member, Repository).resolve).to be_empty
    end
  end
end
