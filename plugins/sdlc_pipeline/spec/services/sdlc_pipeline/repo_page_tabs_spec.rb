require "rails_helper"

RSpec.describe SdlcPipeline::RepoPageTabs do
  it "shows the tab only for an accessible repository" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    other = Factories.user

    expect(described_class.repo_page_tabs(repository: repository, user: owner).first).to include(
      id: "sdlc_pipeline.repository",
      path: "/repositories/#{repository.id}/plugin/sdlc-pipeline",
      component: "sdlc_pipeline/RepositoryPipeline"
    )
    expect(described_class.repo_page_tabs(repository: repository, user: other)).to be_empty
  end
end
