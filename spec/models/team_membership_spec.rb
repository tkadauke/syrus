require "rails_helper"

RSpec.describe TeamMembership do
  let(:team) { Team.create!(name: "Platform") }
  let(:user) { Factories.user }

  it "accepts a valid role" do
    membership = team.team_memberships.build(user: user, role: "member")
    expect(membership).to be_valid
  end

  it "rejects an unknown role" do
    membership = team.team_memberships.build(user: user, role: "admin")
    expect(membership).not_to be_valid
    expect(membership.errors[:role]).to be_present
  end

  it "rejects a duplicate membership for the same user" do
    team.team_memberships.create!(user: user, role: "member")
    duplicate = team.team_memberships.build(user: user, role: "owner")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to be_present
  end

  it "allows the same user on two different teams" do
    other_team = Team.create!(name: "Growth")
    team.team_memberships.create!(user: user, role: "member")
    membership = other_team.team_memberships.build(user: user, role: "member")

    expect(membership).to be_valid
  end
end
