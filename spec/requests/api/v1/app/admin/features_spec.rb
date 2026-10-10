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
    expect(parse_body["beta_mode_enabled"]).to be(false)
    expect(parse_body["categories"]).to eq([
      {
        "category" => "Navigation",
        "features" => [
          {
            "slug" => "new_dashboard",
            "category" => "Navigation",
            "name" => "New dashboard",
            "description" => "Use the redesigned dashboard.",
            "experimental" => false,
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
            "experimental" => false,
            "enabled" => true,
            "name_i18n_key" => "features.slugs.fast_queue.name",
            "description_i18n_key" => nil
          }
        ]
      }
    ])
  end

  it "omits always-hidden flags from the visible feature list" do
    sign_in_as(admin)
    stub_const("Api::V1::App::Admin::FeaturesController::ALWAYS_HIDDEN_SLUGS", %w[unfinished_daemon].freeze)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations + [
      { slug: "unfinished_daemon", category: "Labs", name: "Unfinished daemon", description: "Still under construction.", default_enabled: false }
    ])

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    slugs = parse_body["categories"].flat_map { |category| category["features"].map { |feature| feature["slug"] } }
    expect(slugs).to include("new_dashboard", "fast_queue")
    expect(slugs).not_to include("unfinished_daemon")
  end

  it "refuses to update always-hidden flags through this endpoint" do
    sign_in_as(admin)
    stub_const("Api::V1::App::Admin::FeaturesController::ALWAYS_HIDDEN_SLUGS", %w[unfinished_daemon].freeze)
    Feature.create!(slug: "unfinished_daemon", category: "Labs", name: "Unfinished daemon", enabled: false)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations + [
      { slug: "unfinished_daemon", category: "Labs", name: "Unfinished daemon", description: "Still under construction.", default_enabled: false }
    ])

    patch "/api/v1/app/admin/features/unfinished_daemon", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:not_found)
    expect(Feature.find_by!(slug: "unfinished_daemon")).not_to be_enabled
  end

  it "includes persistent_mcp_sidecar in the visible Labs feature list" do
    sign_in_as(admin)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations + [
      {
        slug: "persistent_mcp_sidecar",
        category: "Labs",
        name: "Persistent MCP sidecar",
        description: "Enables a worker-local persistent MCP sidecar daemon.",
        default_enabled: true,
        name_i18n_key: "features.slugs.persistent_mcp_sidecar.name",
        description_i18n_key: "features.slugs.persistent_mcp_sidecar.description"
      }
    ])

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    labs_features = parse_body["categories"].find { |category| category["category"] == "Labs" }["features"]
    expect(labs_features).to include(
      a_hash_including(
        "slug" => "persistent_mcp_sidecar",
        "name" => "Persistent MCP sidecar",
        "description" => "Enables a worker-local persistent MCP sidecar daemon.",
        "enabled" => true,
        "experimental" => false,
        "name_i18n_key" => "features.slugs.persistent_mcp_sidecar.name",
        "description_i18n_key" => "features.slugs.persistent_mcp_sidecar.description"
      )
    )
  end

  it "updates persistent_mcp_sidecar through this endpoint" do
    sign_in_as(admin)
    Feature.create!(slug: "persistent_mcp_sidecar", category: "Labs", name: "Persistent MCP sidecar", enabled: true)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return(declarations + [
      { slug: "persistent_mcp_sidecar", category: "Labs", name: "Persistent MCP sidecar", description: "Enables a worker-local persistent MCP sidecar daemon.", default_enabled: true }
    ])

    patch "/api/v1/app/admin/features/persistent_mcp_sidecar", params: { feature: { enabled: false } }

    expect(response).to have_http_status(:ok)
    expect(Feature.find_by!(slug: "persistent_mcp_sidecar")).not_to be_enabled
    expect(parse_body["feature"]).to include("slug" => "persistent_mcp_sidecar", "enabled" => false)
  end

  it "blocks enabling beta features until beta mode is enabled" do
    sign_in_as(admin)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return([
      { slug: "new_runtime", category: "Labs", name: "New runtime", description: "Runs beta workloads.", default_enabled: false, experimental: true }
    ])
    Feature.create!(slug: "new_runtime", category: "Labs", name: "New runtime", description: "Runs beta workloads.", enabled: false, experimental: true)

    patch "/api/v1/app/admin/features/new_runtime", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("beta_mode_not_enabled")
    expect(parse_body.fetch("blocked_experimental_features")).to eq([
      { "slug" => "new_runtime", "name" => "New runtime" }
    ])
    expect(Feature.find_by!(slug: "new_runtime")).not_to be_enabled
  end

  it "allows enabling beta features after beta mode is enabled" do
    sign_in_as(admin)
    AppSetting.current.update!(beta_mode_enabled: true)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return([
      { slug: "new_runtime", category: "Labs", name: "New runtime", description: "Runs beta workloads.", default_enabled: false, experimental: true }
    ])
    Feature.create!(slug: "new_runtime", category: "Labs", name: "New runtime", description: "Runs beta workloads.", enabled: false, experimental: true)

    patch "/api/v1/app/admin/features/new_runtime", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:ok)
    expect(Feature.find_by!(slug: "new_runtime")).to be_enabled
    expect(parse_body["feature"]).to include("slug" => "new_runtime", "enabled" => true, "experimental" => true)
  end

  it "reports existing enabled beta features as disabled when beta mode is off" do
    sign_in_as(admin)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return([
      { slug: "existing_beta", category: "Labs", name: "Existing beta", description: "Already enabled before the beta marker.", default_enabled: false, experimental: true }
    ])
    feature = Feature.create!(slug: "existing_beta", category: "Labs", name: "Existing beta", description: "Already enabled before the beta marker.", enabled: true)
    feature.update_column(:experimental, true)

    get "/api/v1/app/admin/features"

    expect(response).to have_http_status(:ok)
    beta_feature = parse_body.fetch("categories").sole.fetch("features").sole
    expect(beta_feature).to include(
      "slug" => "existing_beta",
      "experimental" => true,
      "enabled" => false
    )
  end

  it "updates a declared feature" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/features/new_dashboard", params: { feature: { enabled: true } }

    expect(response).to have_http_status(:ok)
    expect(Feature.find_by!(slug: "new_dashboard")).to be_enabled
    expect(parse_body["feature"]).to include("slug" => "new_dashboard", "enabled" => true, "experimental" => false, "name_i18n_key" => "features.slugs.new_dashboard.name")
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
