require "rails_helper"

RSpec.describe RepositoryFinalApprover do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  it "creates with required attributes" do
    approver = RepositoryFinalApprover.create!(repository: repo, user: user)
    expect(approver.repository).to eq(repo)
    expect(approver.user).to eq(user)
  end

  it "enforces uniqueness of user per repository" do
    RepositoryFinalApprover.create!(repository: repo, user: user)
    duplicate = RepositoryFinalApprover.new(repository: repo, user: user)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to be_present
  end

  it "allows the same user to be a final approver on different repositories" do
    other_repo = Factories.repository(user: user, owner: "other", name: "repo-#{SecureRandom.hex(2)}")
    RepositoryFinalApprover.create!(repository: repo, user: user)
    expect { RepositoryFinalApprover.create!(repository: other_repo, user: user) }.not_to raise_error
  end
end
