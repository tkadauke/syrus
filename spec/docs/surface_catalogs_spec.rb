require "rails_helper"

RSpec.describe "Surface catalogs" do
  before { Rails.application.eager_load! }

  it "matches the live capability surfaces" do
    expect(Syrus::SurfaceCatalogs.committed).to eq(Syrus::SurfaceCatalogs.render_all),
      "surface catalogs are out of date. Run bin/surface-catalogs."
  end

  it "keeps the generated catalogs in the intended documentation surfaces" do
    expect(Syrus::SurfaceCatalogs::CATALOGS).to eq(
      user_api: "website/src/content/docs/generated/user-api-catalog.md",
      admin_api: "config/syrus_docs/admin_api_catalog.md",
      mcp: "config/syrus_docs/mcp_tool_catalog.md",
      cli: "website/src/content/docs/generated/cli-catalog.md"
    )
  end
end
