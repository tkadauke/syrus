require "rails_helper"

RSpec.describe GithubCollaboratorDiscrepancy do
  let(:repository) { Factories.repository }

  it "accepts write and admin permissions" do
    %w[write admin].each do |permission|
      discrepancy = repository.github_collaborator_discrepancies.build(
        github_login: "dev-#{permission}", github_permission: permission, checked_at: Time.current
      )
      expect(discrepancy).to be_valid
    end
  end

  it "rejects a read permission" do
    discrepancy = repository.github_collaborator_discrepancies.build(
      github_login: "reader", github_permission: "read", checked_at: Time.current
    )
    expect(discrepancy).not_to be_valid
    expect(discrepancy.errors[:github_permission]).to be_present
  end

  it "enforces one row per github_login per repository" do
    repository.github_collaborator_discrepancies.create!(github_login: "dev", github_permission: "write", checked_at: Time.current)
    duplicate = repository.github_collaborator_discrepancies.build(github_login: "dev", github_permission: "admin", checked_at: Time.current)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_login]).to be_present
  end

  it "is destroyed when its repository is destroyed" do
    discrepancy = repository.github_collaborator_discrepancies.create!(github_login: "dev", github_permission: "write", checked_at: Time.current)

    repository.destroy!

    expect(GithubCollaboratorDiscrepancy.exists?(discrepancy.id)).to be false
  end
end
