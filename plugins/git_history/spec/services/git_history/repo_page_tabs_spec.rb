require "rails_helper"

RSpec.describe GitHistory::RepoPageTabs do
  let(:owner) { Factories.user }
  let(:collaborator) { Factories.user }
  let(:unrelated_user) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before { repository.repository_memberships.create!(user: collaborator, role: "collaborator") }

  it "returns the Git History tab descriptor for the repository owner" do
    tabs = described_class.repo_page_tabs(repository: repository, user: owner)

    expect(tabs).to contain_exactly(
      include(
        id: "git_history.git_history",
        label: "Git History",
        label_key: "git_history:nav_git_history",
        path: "/repositories/#{repository.id}/plugin/git_history",
        component: "git_history/GitHistory",
        order: 40
      )
    )
  end

  it "returns the tab descriptor for a RepositoryMembership collaborator" do
    tabs = described_class.repo_page_tabs(repository: repository, user: collaborator)

    expect(tabs.map { |tab| tab[:id] }).to include("git_history.git_history")
  end

  it "returns no tabs for a user with no relationship to the repository" do
    tabs = described_class.repo_page_tabs(repository: repository, user: unrelated_user)

    expect(tabs).to eq([])
  end
end
