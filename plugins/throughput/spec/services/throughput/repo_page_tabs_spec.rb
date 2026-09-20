require "rails_helper"

RSpec.describe Throughput::RepoPageTabs do
  let(:owner) { Factories.user }
  let(:collaborator) { Factories.user }
  let(:unrelated_user) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before { repository.repository_memberships.create!(user: collaborator, role: "read") }

  it "returns the Throughput tab descriptor for the repository owner" do
    tabs = described_class.repo_page_tabs(repository: repository, user: owner)

    expect(tabs).to contain_exactly(
      include(
        id: "throughput.repository",
        label: "Throughput",
        label_key: "throughput:tab_throughput",
        path: "/repositories/#{repository.id}/plugin/throughput",
        paths: [ "/repositories/#{repository.id}/plugin/throughput" ],
        component: "throughput/RepositoryThroughput",
        order: 45
      )
    )
  end

  it "returns the tab descriptor for a RepositoryMembership collaborator" do
    tabs = described_class.repo_page_tabs(repository: repository, user: collaborator)

    expect(tabs.map { |tab| tab[:id] }).to include("throughput.repository")
  end

  it "returns no tabs for a user with no relationship to the repository" do
    tabs = described_class.repo_page_tabs(repository: repository, user: unrelated_user)

    expect(tabs).to eq([])
  end
end
