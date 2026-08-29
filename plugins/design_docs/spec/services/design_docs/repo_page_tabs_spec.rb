require "rails_helper"

RSpec.describe DesignDocs::RepoPageTabs do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  it "declares the repository design docs tab for accessible repositories" do
    doc = DesignDoc.create!(owner_user: owner, title: "Plan", markdown: "Body", visibility: "private")
    doc.repositories << repository

    tabs = described_class.repo_page_tabs(repository: repository, user: owner)

    expect(tabs).to contain_exactly(
      include(
        id: "design_docs.repository",
        label: "Design Docs",
        path: "/repositories/#{repository.id}/plugin/design_docs",
        component: "design_docs/RepositoryDesignDocs",
        badge: 1
      )
    )
  end
end
