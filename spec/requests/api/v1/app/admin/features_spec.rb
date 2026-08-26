require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/features", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }
  let(:declarations) do
    [
      { slug: "new_dashboard", category: "Navigation", name: "New dashboard", description: "Use the redesigned dashboard.", default_enabled: false, name_i18n_key: "features.slugs.new_dashboard.name", description_i18n_key: "features.slugs.new_dashboard.description" },
      { slug: "fast_queue", category: "Operations", name: "Fast queue", description: nil, default_enabled: true, name_i18n_key: "features.slugs.fast_queue.name", description_i18n_key: nil }
    ]
  end

  def parse_body
    JSON.parse(response.body)
  end

  before do
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations)
    Feature.create!(slug: "new_dashboard", category: "Navigation", name: "New dashboard", description: "Use the redesigned dashboard.", enabled: false)
    Feature.create!(slug: "fast_queue", category: "Operations", name: "Fast queue", enabled: true)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns declared features grouped by category" do
    sign_in_as(admin)

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    expect(parse_body["categories"]).to eq([
      {
        "category" => "Navigation",
        "features" => [
          {
            "slug" => "new_dashboard",
            "category" => "Navigation",
            "name" => "New dashboard",
            "description" => "Use the redesigned dashboard.",
            "enabled" => false,
            "name_i18n_key" => "features.slugs.new_dashboard.name",
            "description_i18n_key" => "features.slugs.new_dashboard.description"
          }
        ]
      },
      {
        "category" => "Operations",
        "features" => [
          {
            "slug" => "fast_queue",
            "category" => "Operations",
            "name" => "Fast queue",
            "description" => nil,
            "enabled" => true,
            "name_i18n_key" => "features.slugs.fast_queue.name",
            "description_i18n_key" => nil
          }
        ]
      }
    ])
  end

  it "omits developer-only mode flags in simple mode" do
    sign_in_as(admin)
    AppSetting.current.update!(mode: "simple", mode_configured_at: Time.current)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations + [
      { slug: "coding_mode", category: "Labs", name: "Coding mode", description: "Write code from chat.", default_enabled: false },
      { slug: "local_mode", category: "Labs", name: "Local mode", description: "Connect local repos.", default_enabled: false }
    ])

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    slugs = parse_body["categories"].flat_map { |category| category["features"].map { |feature| feature["slug"] } }
    expect(slugs).to include("new_dashboard", "fast_queue")
    expect(slugs).not_to include("coding_mode", "local_mode")
  end

  it "updates a declared feature" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/features/new_dashboard", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:ok)
    expect(Feature.find_by!(slug: "new_dashboard")).to be_enabled
    expect(parse_body["feature"]).to include("slug" => "new_dashboard", "enabled" => true, "name_i18n_key" => "features.slugs.new_dashboard.name")
  end

  it "deduplicates features with the same slug declared multiple times" do
    sign_in_as(admin)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return([
      { slug: "new_dashboard", category: "Navigation", name: "New dashboard", description: "First copy.", default_enabled: false },
      { slug: "new_dashboard", category: "Navigation", name: "New dashboard", description: "Duplicate copy.", default_enabled: false }
    ])

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    nav_features = parse_body["categories"].find { |c| c["category"] == "Navigation" }["features"]
    expect(nav_features.map { |f| f["slug"] }).to eq(["new_dashboard"])
  end

  it "does not update undeclared features" do
    sign_in_as(admin)
    Feature.create!(slug: "old_feature", category: "Old", name: "Old feature", enabled: false)

    patch "/api/v1/app/admin/features/old_feature", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(Feature.find_by!(slug: "old_feature")).not_to be_enabled
  end
end
