require "rails_helper"

RSpec.describe DesignDocs::SidebarPages do
  it "declares the top-level design docs sidebar page" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "design_docs.index",
        label: "Design Docs",
        path: "/design_docs",
        component: "design_docs/DesignDocs",
        icon: "document",
        smart_folder_api_path: "/api/v1/app/design_docs",
        smart_folder_subject: "design_doc"
      )
    )
  end

  # `paths` is what Rails' SPA wildcard and the React router both derive from.
  # Declaring only the index left /design_docs/22 rendering the bare bootstrap
  # shell, even though DesignDocs.tsx already branched on params.id.
  it "declares the detail path as well as the index" do
    expect(described_class.sidebar_pages.first[:paths]).to eq([ "/design_docs", "/design_docs/:id" ])
  end
end
