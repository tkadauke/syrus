require "rails_helper"

RSpec.describe Repositories::PluginRepoTabsPayload do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:unrelated_user) { Factories.user(email_address: "unrelated@example.com") }
  let(:repository) { Factories.repository(user: owner) }

  before do
    repository.repository_memberships.create!(user: collaborator, role: "collaborator")

    provider = Class.new do
      include Syrus::Plugin::RepoPageTab

      # Mirrors a realistic provider: visibility computed per repo/user,
      # exercising the extension point's repository:/user: contract.
      def self.repo_page_tabs(repository:, user:)
        accessible = repository.user_id == user.id || RepositoryMembership.exists?(repository_id: repository.id, user: user)
        return [] unless accessible

        [ { id: "git_history.git_history", label: "Git History", path: "/repositories/#{repository.id}/plugin/git_history" } ]
      end
    end
    Syrus::PluginRegistry.register(name: "tab-plugin", version: "0.1.0", provides: { repo_page_tab: provider })
  end

  after { Syrus::PluginRegistry.reset! }

  it "includes the provider's tabs for the repository owner" do
    tabs = described_class.tabs_for(repository: repository, user: owner)

    expect(tabs.map { |tab| tab[:id] }).to include("git_history.git_history")
  end

  it "includes the provider's tabs for a RepositoryMembership collaborator" do
    tabs = described_class.tabs_for(repository: repository, user: collaborator)

    expect(tabs.map { |tab| tab[:id] }).to include("git_history.git_history")
  end

  it "excludes the provider's tabs for an unrelated user" do
    tabs = described_class.tabs_for(repository: repository, user: unrelated_user)

    expect(tabs.map { |tab| tab[:id] }).not_to include("git_history.git_history")
  end

  it "normalizes descriptors into the payload shape" do
    tabs = described_class.tabs_for(repository: repository, user: owner)

    expect(tabs).to contain_exactly(
      include(
        id: "git_history.git_history",
        label: "Git History",
        path: "/repositories/#{repository.id}/plugin/git_history",
        paths: [ "/repositories/#{repository.id}/plugin/git_history" ],
        order: 0
      )
    )
  end
end
