require "rails_helper"

RSpec.describe EpicPolicy do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
  # other lets are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:other_user) { admin && Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:epic) { Factories.epic(user: owner, repository: repository, owner_user: owner) }

  describe "#unclaim?" do
    it "allows the current claimant" do
      expect(described_class.new(owner, epic)).to be_unclaim
    end

    it "denies another user" do
      expect(described_class.new(other_user, epic)).not_to be_unclaim
    end

    it "allows a global admin regardless of ownership" do
      expect(described_class.new(admin, epic)).to be_unclaim
    end
  end

  describe "#reassign?" do
    it "requires admin when reassigning via the owner_user_id param" do
      expect(described_class.new(other_user, epic).reassign?(via_owner_user_id_param: true)).to eq(false)
      expect(described_class.new(admin, epic).reassign?(via_owner_user_id_param: true)).to eq(true)
    end

    it "does not require admin via the legacy owner_id param" do
      expect(described_class.new(other_user, epic).reassign?(via_owner_user_id_param: false)).to eq(true)
    end
  end

  describe "#advance_state?" do
    let(:product_owner) { Factories.user(role: "product_owner") }
    let(:developer) { Factories.user(role: "developer") }

    it "blocks product owners from advancing into ready/in_progress/done" do
      policy = described_class.new(product_owner, nil)

      expect(policy.advance_state?(target_state: "ready")).to eq(false)
      expect(policy.advance_state?(target_state: "in_progress")).to eq(false)
      expect(policy.advance_state?(target_state: "done")).to eq(false)
    end

    it "allows product owners to move to states outside the advancement list" do
      policy = described_class.new(product_owner, nil)

      expect(policy.advance_state?(target_state: "backlog")).to eq(true)
    end

    it "allows developers to advance freely" do
      policy = described_class.new(developer, nil)

      expect(policy.advance_state?(target_state: "in_progress")).to eq(true)
    end
  end

  describe "Scope#resolve" do
    it "returns only epics on repositories the user is a member of, matching Epic.accessible_to" do
      accessible = epic
      Factories.epic(user: other_user, repository: Factories.repository(user: other_user))

      resolved = described_class::Scope.new(owner, Epic).resolve

      expect(resolved).to contain_exactly(accessible)
    end

    it "does not bypass for a global admin (only the per-action predicates do)" do
      epic
      foreign = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))

      resolved = described_class::Scope.new(admin, Epic).resolve

      expect(resolved).not_to include(foreign)
    end

    it "includes epics on repositories granted via a team, mirroring a direct membership" do
      team_member = other_user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: repository, role: "read")

      resolved = described_class::Scope.new(team_member, Epic).resolve

      expect(resolved).to contain_exactly(epic)
    end
  end
end
