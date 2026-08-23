require "rails_helper"

RSpec.describe TeamRepository do
  let(:team) { Team.create!(name: "Platform") }
  let(:repository) { Factories.repository }

  it "accepts a valid role" do
    grant = team.team_repositories.build(repository: repository, role: "read")
    expect(grant).to be_valid
  end

  it "rejects an unknown role" do
    grant = team.team_repositories.build(repository: repository, role: "owner")
    expect(grant).not_to be_valid
    expect(grant.errors[:role]).to be_present
  end

  it "rejects a duplicate grant for the same repository" do
    team.team_repositories.create!(repository: repository, role: "read")
    duplicate = team.team_repositories.build(repository: repository, role: "write")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:team_id]).to be_present
  end

  it "allows the same team to be granted on two different repositories" do
    other_repository = Factories.repository
    team.team_repositories.create!(repository: repository, role: "read")
    grant = team.team_repositories.build(repository: other_repository, role: "write")

    expect(grant).to be_valid
  end

  describe ".at_least" do
    it "matches grants at or above the given tier" do
      reader_repo = Factories.repository
      writer_repo = Factories.repository
      admin_repo = Factories.repository
      reader = team.team_repositories.create!(repository: reader_repo, role: "read")
      writer = team.team_repositories.create!(repository: writer_repo, role: "write")
      admin_grant = team.team_repositories.create!(repository: admin_repo, role: "admin")

      expect(team.team_repositories.at_least("write")).to contain_exactly(writer, admin_grant)
      expect(team.team_repositories.at_least("admin")).to contain_exactly(admin_grant)
      expect(team.team_repositories.at_least("read")).to contain_exactly(reader, writer, admin_grant)
    end
  end
end
