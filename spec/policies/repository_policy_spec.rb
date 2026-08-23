require "rails_helper"

RSpec.describe RepositoryPolicy do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
  # other lets are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:other_user) { admin && Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  describe "#show?" do
    it "allows the owning user" do
      expect(described_class.new(owner, repository)).to be_show
    end

    it "denies a non-owning user" do
      expect(described_class.new(other_user, repository)).not_to be_show
    end

    it "allows a global admin regardless of ownership" do
      expect(described_class.new(admin, repository)).to be_show
    end
  end

  describe "#update? and #destroy?" do
    it "mirror #show?" do
      policy = described_class.new(other_user, repository)
      expect(policy.update?).to eq(policy.show?)
      expect(policy.destroy?).to eq(policy.show?)
    end
  end

  describe "Scope#resolve" do
    it "returns only the user's own repositories, matching Current.user.repositories" do
      owned = repository
      Factories.repository(user: other_user)

      resolved = described_class::Scope.new(owner, Repository).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "does not bypass for a global admin (only the per-record predicates do)" do
      repository
      foreign = Factories.repository(user: other_user)

      resolved = described_class::Scope.new(admin, Repository).resolve

      expect(resolved).not_to include(foreign)
    end
  end
end
