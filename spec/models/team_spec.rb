require "rails_helper"

RSpec.describe Team do
  it "requires a name" do
    team = Team.new
    expect(team).not_to be_valid
    expect(team.errors[:name]).to be_present
  end

  it "rejects a case-insensitively duplicate name" do
    Team.create!(name: "Platform")
    duplicate = Team.new(name: "platform")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to be_present
  end

  describe "#owned_by?" do
    it "is true for a user with an owner-role membership" do
      team = Team.create!(name: "Platform")
      owner = Factories.user
      team.team_memberships.create!(user: owner, role: "owner")

      expect(team.owned_by?(owner)).to be true
    end

    it "is false for a user with only a member-role membership" do
      team = Team.create!(name: "Platform")
      member = Factories.user
      team.team_memberships.create!(user: member, role: "member")

      expect(team.owned_by?(member)).to be false
    end

    it "is false for a user with no membership" do
      team = Team.create!(name: "Platform")
      expect(team.owned_by?(Factories.user)).to be false
    end

    it "is false for a nil user" do
      team = Team.create!(name: "Platform")
      expect(team.owned_by?(nil)).to be false
    end
  end
end
