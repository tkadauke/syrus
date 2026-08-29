require "rails_helper"

RSpec.describe DesignDocs::SidebarPages do
  it "declares the top-level design docs sidebar page" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "design_docs.index",
        label: "Design Docs",
        path: "/design_docs",
        component: "design_docs/DesignDocs",
        icon: "document"
      )
    )
  end
end
