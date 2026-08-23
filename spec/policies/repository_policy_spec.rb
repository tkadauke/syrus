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
  end
end
