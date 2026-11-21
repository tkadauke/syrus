require "rails_helper"

RSpec.describe ReviewWorkspacePlugin::SidebarPages do
  it "declares the list and deep-link routes with a badge endpoint" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "review_workspace.review",
        label: "Review",
        paths: [ "/review", "/review/:job_id" ],
        component: "review_workspace/ReviewWorkspace",
        badge_api_path: "/api/v1/app/review_workspace/count"
      )
    )
  end
end
