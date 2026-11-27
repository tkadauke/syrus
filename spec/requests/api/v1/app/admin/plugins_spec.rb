require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/plugins", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) do
    admin
    Factories.user(admin: false)
  end

  def parse_body = JSON.parse(response.body)
  def encoded_filter(tree) = Filters::QueryParam.encode(tree)

  after do
    Syrus::PluginRegistry.reset!
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "clears one local plugin quarantine and requires a restart" do
    sign_in_as(admin)
    safety = instance_double(Syrus::PluginBootSafety)
    allow(Syrus::PluginBootSafety).to receive(:default).and_return(safety)
    allow(safety).to receive(:locally_clearable?).with("weather").and_return(true)
    allow(safety).to receive(:clear!).with("weather").and_return(true)

    post "/api/v1/app/admin/plugins/weather/clear_quarantine"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("ok" => true, "plugin" => "weather", "restart_required" => true)
    expect(safety).to have_received(:clear!).with("weather")
  end

  it "rejects clearing a quarantine controlled by safe mode or fleet state" do
    sign_in_as(admin)
    safety = instance_double(Syrus::PluginBootSafety, locally_clearable?: false)
    allow(Syrus::PluginBootSafety).to receive(:default).and_return(safety)

    post "/api/v1/app/admin/plugins/weather/clear_quarantine"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("quarantine_not_locally_clearable")
  end

  it "shows a newly recorded local quarantine before the process restarts" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "weather", version: "1.0.0")
    safety = instance_double(
      Syrus::PluginBootSafety,
      mode: nil,
      quarantines: { "weather" => "manually quarantined by an administrator" },
      local_quarantines: { "weather" => "manually quarantined by an administrator" },
      fleet_quarantines: {}
    )
    allow(Syrus::PluginBootSafety).to receive(:default).and_return(safety)

    get "/api/v1/app/admin/plugins"

    plugin = parse_body.fetch("plugins").sole
    expect(plugin).to include(
      "name" => "weather",
      "health" => {
        "state" => "quarantined",
        "reasons" => [ "manually quarantined by an administrator" ]
      },
      "quarantine_clearable" => true
    )
  end

  it "returns slim registered-plugin rows" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    repository = Factories.repository(user: admin)
    AdminPluginsSpec::CustomInputSource.create!(user: admin, repository: repository)
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "visibility-plugin",
      display_name: "Visibility",
      display_name_i18n_key: "visibility:plugin.display_name",
      version: "1.2.3",
      description: "Adds visible things.",
      description_i18n_key: "visibility:plugin.description",
      long_description: "Adds a longer explanation.",
      long_description_i18n_key: "visibility:plugin.long_description",
      homepage: "https://example.test/plugin",
      author: "Ada",
      source: "internal",
      frontend: {
        routes: {
          "visibility/Admin" => "app/frontend/routes/Admin.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/visibility.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/admin/visibility",
          controller: "visibility/admin#show"
        }
      ],
      provides: {
        agent_provider: AdminPluginsSpec::AvailableProvider,
        input_source: AdminPluginsSpec::CustomInputSource
      }
    )

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    plugin = parse_body.fetch("plugins").sole
    expect(plugin).to include(
      "name" => "visibility-plugin",
      "display_name" => "Visibility",
      "display_name_i18n_key" => "visibility:plugin.display_name",
      "disable_blockers" => [
        {
          "kind" => "configured_input_sources",
          "label" => "Configured input sources use AdminPluginsSpec::CustomInputSource",
          "count" => 1
        }
      ],
      "version" => "1.2.3",
      "enabled" => true,
      "default_enabled" => true,
      "disableable" => true,
      "experimental" => false,
      "description" => "Adds visible things.",
      "description_i18n_key" => "visibility:plugin.description"
    )
    expect(plugin).not_to include("long_description", "homepage", "author", "source", "frontend", "routes", "extension_points", "config_schema", "config")
  end

  it "includes icon_url when the manifest sets one" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "iconed-plugin",
      version: "1.0.0",
      icon_url: "/plugin-icons/iconed-plugin.svg"
    )

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("icon_url" => "/plugin-icons/iconed-plugin.svg")
  end

  it "falls back to the SPQR eagle icon when the manifest has no icon_url" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "iconless-plugin", version: "1.0.0")

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("icon_url" => "/plugin-icons/spqr_eagle.svg")
  end

  it "includes a human-readable category_label alongside the raw category key" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "categorized-plugin",
      version: "1.0.0",
      category: "agent_capability"
    )

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include(
      "category" => "agent_capability",
      "category_label" => "Agent capability"
    )
  end

  it "returns a nil category_label when the manifest has no category" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "uncategorized-plugin", version: "1.0.0")

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("category" => nil, "category_label" => nil)
  end

  it "filters plugins by a full text search chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "search-target-plugin",
      display_name: "Weather Radar",
      version: "1.0.0",
      description: "Watches storms roll in.",
      category: "observability",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "search-other-plugin",
      display_name: "Ticket Sync",
      version: "1.0.0",
      description: "Keeps issues in sync.",
      category: "connectivity"
    )

    tree = { "and" => [ { "field" => "search", "op" => "contains", "value" => "storms" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "search-target-plugin" ])
    expect(parse_body.fetch("filter")).to eq(tree)
  end

  it "filters plugins by category chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "observability-plugin", version: "1.0.0", category: "observability")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "connectivity-plugin", version: "1.0.0", category: "connectivity")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "uncategorized-search-plugin", version: "1.0.0")

    tree = { "and" => [ { "field" => "category", "op" => "is", "value" => "observability" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "observability-plugin" ])
  end

  it "filters plugins by enabled state chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "enabled-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "disabled-plugin", version: "1.0.0")
    PluginRecord.find_by!(name: "disabled-plugin").update!(enabled: false)

    tree = { "and" => [ { "field" => "enabled", "op" => "is", "value" => "disabled" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "disabled-plugin" ])
  end

  it "filters plugins by experimental status chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "stable-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(disableable: true, requires_syrus: nil, name: "experimental-plugin", version: "1.0.0", experimental: true, default_enabled: false)

    tree = { "and" => [ { "field" => "experimental", "op" => "is", "value" => "experimental" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "experimental-plugin" ])
  end

  it "filters plugins by author chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "ada-plugin", version: "1.0.0", author: "Ada Lovelace")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "grace-plugin", version: "1.0.0", author: "Grace Hopper")

    tree = { "and" => [ { "field" => "author", "op" => "contains", "value" => "Ada" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "ada-plugin" ])
  end

  it "filters plugins by extension point chip" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "agent-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "input-plugin",
      version: "1.0.0",
      provides: { input_source: AdminPluginsSpec::CustomInputSource }
    )

    tree = { "and" => [ { "field" => "extension_point", "op" => "is", "value" => "input_source" } ] }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "input-plugin" ])
  end

  it "combines category and search chips with AND semantics" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "both-match-plugin", version: "1.0.0", category: "observability",
      description: "Watches storms roll in."
    )
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "category-only-plugin", version: "1.0.0", category: "observability",
      description: "Nothing weather related here."
    )

    tree = {
      "and" => [
        { "field" => "category", "op" => "is", "value" => "observability" },
        { "field" => "search", "op" => "contains", "value" => "storms" }
      ]
    }
    get "/api/v1/app/admin/plugins", params: { q: encoded_filter(tree) }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "both-match-plugin" ])
  end

  it "exposes the admin_plugins filter_schema for the chip filter UI" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    fields = parse_body.dig("controls", "filter_schema").map { |chip| chip["field"] }
    expect(fields).to contain_exactly("enabled", "experimental", "author", "extension_point", "category", "search")
    enabled_chip = parse_body.dig("controls", "filter_schema").find { |chip| chip["field"] == "enabled" }
    expect(enabled_chip["values"]).to include("value" => "enabled", "label" => "Enabled")
    experimental_chip = parse_body.dig("controls", "filter_schema").find { |chip| chip["field"] == "experimental" }
    expect(experimental_chip["values"]).to include("value" => "experimental", "label" => "Experimental")
    extension_point_chip = parse_body.dig("controls", "filter_schema").find { |chip| chip["field"] == "extension_point" }
    expect(extension_point_chip["values"]).to include("value" => "input_source", "label" => "Input source")
    category_chip = parse_body.dig("controls", "filter_schema").find { |chip| chip["field"] == "category" }
    expect(category_chip["bucket"]).to eq("enum")
    expect(category_chip["values"]).to include("value" => "observability", "label" => "Observability")
  end

  it "returns every plugin when no filter is applied" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "unfiltered-plugin", version: "1.0.0")

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "unfiltered-plugin" ])
    expect(parse_body.fetch("filter")).to eq("and" => [])
  end

  it "handles zero plugins gracefully" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins")).to eq([])
  end

  it "includes depends_on and derived dependents in the plugin payload" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "payload-ruby-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "payload-rails-plugin", version: "1.0.0", depends_on: [ "payload-ruby-plugin" ])

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    plugins = parse_body.fetch("plugins").index_by { |p| p["name"] }
    expect(plugins.fetch("payload-ruby-plugin")).to include("depends_on" => [], "dependents" => [ "payload-rails-plugin" ])
    expect(plugins.fetch("payload-rails-plugin")).to include("depends_on" => [ "payload-ruby-plugin" ], "dependents" => [])
  end

  it "reflects agent provider availability" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "offline-provider",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::UnavailableProvider }
    )

    get "/api/v1/app/admin/plugins/offline-provider"

    extension = parse_body.dig("plugin", "extension_points", 0)
    expect(extension.fetch("availability")).to include("status" => "unavailable", "label" => "Unavailable")
  end

  it "enables and disables an installed disableable plugin live" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "toggle-plugin",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/app/admin/plugins/toggle-plugin/disable"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("v" => 1, "ok" => true, "plugin" => { "name" => "toggle-plugin", "enabled" => false })
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to eq([])

    post "/api/v1/app/admin/plugins/toggle-plugin/enable"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("v" => 1, "ok" => true, "plugin" => { "name" => "toggle-plugin", "enabled" => true })
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to eq([ AdminPluginsSpec::AvailableProvider ])
  end

  it "cascades enabling a plugin's dependencies" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "ruby-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "rails-plugin", version: "1.0.0", depends_on: [ "ruby-plugin" ])
    PluginRecord.find_by!(name: "ruby-plugin").update!(enabled: false)
    PluginRecord.find_by!(name: "rails-plugin").update!(enabled: false)

    post "/api/v1/app/admin/plugins/rails-plugin/enable"

    expect(response).to have_http_status(:ok)
    expect(PluginRecord.find_by!(name: "ruby-plugin").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "rails-plugin").enabled).to be(true)
  end

  it "blocks enabling an experimental plugin until the instance opts in" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(disableable: true, requires_syrus: nil, name: "experimental-plugin", version: "1.0.0", experimental: true, default_enabled: false)

    post "/api/v1/app/admin/plugins/experimental-plugin/enable"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body).to include(
      "message" => "This plugin is available in this Syrus build, but this instance has not enabled beta mode."
    )
    expect(parse_body.fetch("blocked_experimental_plugins")).to eq([
      { "name" => "experimental-plugin", "display_name" => "Experimental Plugin" }
    ])
    expect(PluginRecord.find_by!(name: "experimental-plugin").enabled).to be(false)
  end

  it "blocks the whole enable action when a dependency cascade would enable an experimental plugin" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(disableable: true, requires_syrus: nil, name: "experimental-dependency", version: "1.0.0", experimental: true, default_enabled: false)
    Syrus::PluginRegistry.register(disableable: true, experimental: false, requires_syrus: nil, name: "stable-plugin", version: "1.0.0", default_enabled: false, depends_on: [ "experimental-dependency" ])

    post "/api/v1/app/admin/plugins/stable-plugin/enable"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.fetch("blocked_experimental_plugins")).to eq([
      { "name" => "experimental-dependency", "display_name" => "Experimental Dependency" }
    ])
    expect(PluginRecord.find_by!(name: "stable-plugin").enabled).to be(false)
    expect(PluginRecord.find_by!(name: "experimental-dependency").enabled).to be(false)
  end

  it "enables an experimental plugin after the instance opts in" do
    sign_in_as(admin)
    AppSetting.current.update!(beta_mode_enabled: true)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(disableable: true, requires_syrus: nil, name: "experimental-plugin", version: "1.0.0", experimental: true, default_enabled: false)

    post "/api/v1/app/admin/plugins/experimental-plugin/enable"

    expect(response).to have_http_status(:ok)
    expect(PluginRecord.find_by!(name: "experimental-plugin").enabled).to be(true)
  end

  it "warns instead of disabling when other enabled plugins depend on the target" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "ruby-dep-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "rails-dep-plugin", version: "1.0.0", depends_on: [ "ruby-dep-plugin" ])

    post "/api/v1/app/admin/plugins/ruby-dep-plugin/disable"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["requires_confirmation"]).to be(true)
    expect(body["plugin_name"]).to eq("ruby-dep-plugin")
    expect(body["dependents"]).to eq([ "rails-dep-plugin" ])
    expect(PluginRecord.find_by!(name: "ruby-dep-plugin").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "rails-dep-plugin").enabled).to be(true)
  end

  it "cascades disabling a plugin's dependents once confirmed" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "ruby-confirm-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "rails-confirm-plugin", version: "1.0.0", depends_on: [ "ruby-confirm-plugin" ])

    post "/api/v1/app/admin/plugins/ruby-confirm-plugin/disable", params: { confirm_cascade: true }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("v" => 1, "ok" => true, "plugin" => { "name" => "ruby-confirm-plugin", "enabled" => false })
    expect(PluginRecord.find_by!(name: "ruby-confirm-plugin").enabled).to be(false)
    expect(PluginRecord.find_by!(name: "rails-confirm-plugin").enabled).to be(false)
  end

  it "does not warn when disabling a plugin with no dependents (unchanged behavior)" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "no-dependents-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/app/admin/plugins/no-dependents-plugin/disable"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["requires_confirmation"]).to be_nil
    expect(body.fetch("plugin")).to include("name" => "no-dependents-plugin", "enabled" => false)
  end

  describe "GET /api/v1/app/admin/plugins/:name" do
    it "returns one plugin with docs, links, metrics, routes, config, and enabled state" do
      original_metrics_registry = Syrus::Metrics.registry
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::Metrics.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "detail_plugin",
        version: "1.0.0",
        display_name: "Detail Plugin",
        description: "Short detail.",
        long_description: "Long detail.",
        author: "Ada",
        homepage: "https://example.test/detail",
        category: "tooling",
        links: [
          { label: "Open Detail", href: "/detail", description: "Primary surface", kind: "surface", enabled_only: true }
        ],
        metrics: [
          { "name" => "syrus_detail_plugin_runs_total", "type" => "counter", "tags" => [ "state" ], "comment" => "Runs", "owner" => "detail_plugin" }
        ],
        routes: [
          { verb: "GET", path: "/api/v1/app/detail", controller: "detail#index" }
        ],
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string }
        ],
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
      )
      Syrus::Metrics.declare_plugin("detail_plugin") { counter :runs_total, tags: %i[state], comment: "Runs" }

      get "/api/v1/app/admin/plugins/detail_plugin"

      expect(response).to have_http_status(:ok)
      plugin = parse_body.fetch("plugin")
      expect(plugin).to include(
        "name" => "detail_plugin",
        "display_name" => "Detail Plugin",
        "enabled" => true,
        "long_description" => "Long detail.",
        "links" => [
          { "label" => "Open Detail", "href" => "/detail", "description" => "Primary surface", "kind" => "surface", "enabled_only" => true }
        ],
        "routes" => [
          { "verb" => "GET", "path" => "/api/v1/app/detail", "controller" => "detail#index" }
        ]
      )
      expect(plugin.fetch("config_schema")).to include("key" => "hostname", "label" => "Hostname", "type" => "string")
      expect(plugin.fetch("metrics")).to contain_exactly(
        include(
          "name" => "syrus_detail_plugin_runs_total",
          "type" => "counter",
          "tags" => [ "state" ],
          "comment" => "Runs",
          "available" => true
        )
      )
      expect(plugin.fetch("docs")).to eq([])
    ensure
      # A bare Metrics.reset! here would leave the process-wide registry
      # permanently empty for every later spec in this worker -- core
      # metrics like syrus_admission_decisions_total are declared once, at
      # class-load time, and nothing re-declares them on demand (see
      # Syrus::Metrics::Registry#reset! and config/initializers/metrics.rb).
      # Restore the pre-test registry instead, the same pattern every other
      # Metrics.reset!-using spec follows (see spec/lib/syrus/metrics_spec.rb).
      Syrus::Metrics.instance_variable_set(:@registry, original_metrics_registry)
    end

    it "returns plugin-owned docs for bundled plugins without moving them into core docs" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      require Rails.root.join("plugins/terminal/lib/terminal")
      Terminal.register!

      get "/api/v1/app/admin/plugins/terminal"

      expect(response).to have_http_status(:ok)
      plugin = parse_body.fetch("plugin")
      expect(plugin.fetch("docs")).to include(
        include(
          "title" => "Terminal",
          "path" => "plugins/terminal/docs/syrus_docs/terminal.md",
          "body" => include("## Enabling")
        )
      )
      expect(plugin.fetch("links")).to include(
        "label" => "Open Terminal",
        "href" => "/terminal",
        "description" => "Open the top-level Terminal workspace browser.",
        "kind" => "surface",
        "enabled_only" => true
      )
    end

    it "returns disabled state and unavailable declared metrics for disabled plugins" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "disabled-detail-plugin",
        version: "1.0.0",
        metrics: [
          { "name" => "syrus_disabled_detail_plugin_runs_total", "type" => "counter", "tags" => [], "comment" => "Runs", "owner" => "disabled-detail-plugin" }
        ]
      )
      PluginRecord.find_by!(name: "disabled-detail-plugin").update!(enabled: false)

      get "/api/v1/app/admin/plugins/disabled-detail-plugin"

      expect(response).to have_http_status(:ok)
      plugin = parse_body.fetch("plugin")
      expect(plugin).to include("enabled" => false)
      expect(plugin.fetch("metrics")).to contain_exactly(include("available" => false))
    end

    it "404s for a missing plugin" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!

      get "/api/v1/app/admin/plugins/missing-plugin"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end

  it "rejects disabling a non-disableable plugin" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, experimental: false, requires_syrus: nil,
      name: "required-plugin",
      version: "0.1.0",
      disableable: false,
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/app/admin/plugins/required-plugin/disable"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("plugin_not_disableable")
    expect(PluginRecord.find_by!(name: "required-plugin").enabled).to be(true)
  end

  it "rejects disabling a plugin while configured resources use it" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "used-plugin",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    admin.update!(agent_provider: "available")

    get "/api/v1/app/admin/plugins"
    expect(parse_body.dig("plugins", 0, "disable_blockers")).to include(
      include("kind" => "configured_users", "count" => 1)
    )

    post "/api/v1/app/admin/plugins/used-plugin/disable"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("plugin_in_use")
    expect(PluginRecord.find_by!(name: "used-plugin").enabled).to be(true)
  end

  describe "GET /api/v1/app/admin/plugins/:name/config" do
    it "403s for non-admin users" do
      sign_in_as(non_admin)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "config-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string }
        ]
      )

      get "/api/v1/app/admin/plugins/config-plugin/config"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns config_schema and current config values" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "schema-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Device Hostname", type: :string, required: false },
          { key: "exit_node", label: "Advertise exit node", type: :boolean, default: false }
        ]
      )

      get "/api/v1/app/admin/plugins/schema-plugin/config"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config_schema"]).to contain_exactly(
        { "key" => "hostname", "label" => "Device Hostname", "type" => "string", "required" => false },
        { "key" => "exit_node", "label" => "Advertise exit node", "type" => "boolean", "default" => false }
      )
      expect(body["config"]).to eq("exit_node" => false, "hostname" => nil)
    end

    it "returns { present: bool } for secret_env entries and never the raw value" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "secret-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY",
            required: true, description: "Set in .env — not stored in DB" }
        ]
      )

      previous = ENV["TS_TEST_AUTHKEY"]
      ENV["TS_TEST_AUTHKEY"] = "s3cr3t"
      begin
        get "/api/v1/app/admin/plugins/secret-plugin/config"
      ensure
        previous.nil? ? ENV.delete("TS_TEST_AUTHKEY") : ENV["TS_TEST_AUTHKEY"] = previous
      end

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config"]["auth_key"]).to eq("present" => true)
      expect(body.to_json).not_to include("s3cr3t")

      get "/api/v1/app/admin/plugins/secret-plugin/config"

      expect(parse_body["config"]["auth_key"]).to eq("present" => false)
    end
  end

  describe "PATCH /api/v1/app/admin/plugins/:name/config" do
    it "403s for non-admin users" do
      sign_in_as(non_admin)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "config-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string }
        ]
      )

      patch "/api/v1/app/admin/plugins/config-plugin/config", params: { config: { hostname: "myhost" } }

      expect(response).to have_http_status(:forbidden)
    end

    it "persists non-secret config values to PluginRecord#config settings" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "writable-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string },
          { key: "exit_node", label: "Exit node", type: :boolean, default: false }
        ]
      )

      patch "/api/v1/app/admin/plugins/writable-plugin/config",
            params: { config: { hostname: "myhost", exit_node: true } }.to_json,
            headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config"]).to eq("hostname" => "myhost", "exit_node" => true)

      record = PluginRecord.find_by!(name: "writable-plugin")
      expect(record.config["settings"]).to eq("hostname" => "myhost", "exit_node" => true)
    end

    it "ignores secret_env keys and does not persist them" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "secret-write-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string },
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY" }
        ]
      )

      patch "/api/v1/app/admin/plugins/secret-write-plugin/config",
            params: { config: { hostname: "myhost", auth_key: "should-not-be-stored" } }

      expect(response).to have_http_status(:ok)
      record = PluginRecord.find_by!(name: "secret-write-plugin")
      expect(record.config.to_h["settings"]).not_to have_key("auth_key")
      expect(record.config.to_h["settings"]).to eq("hostname" => "myhost")
    end
  end

  describe "plugin health" do
    it "reports an open runtime circuit" do
      provider = Class.new { include Syrus::Plugin::Callbacks }
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "runtime-failure-plugin", version: "1.0.0", provides: { callbacks: provider }
      )
      Syrus::PluginInvocation.call(
        extension_point: :callbacks, provider: provider, operation: :call,
        failure_threshold: 1, cooldown: 75, on_decline: nil
      ) { raise "provider unavailable" }
      admin = Factories.user(admin: true)
      sign_in_as(admin)

      get "/api/v1/app/admin/plugins"

      entry = response.parsed_body["plugins"].find { |plugin| plugin["name"] == "runtime-failure-plugin" }
      expect(entry.dig("health", "state")).to eq("circuit_open")
      circuit = entry.dig("health", "circuits", 0)
      expect(circuit).to include(
        "extension_point" => "callbacks", "state" => "open", "failure_count" => 1
      )
      expect(Time.iso8601(circuit.fetch("retry_at")) - Time.iso8601(circuit.fetch("opened_at"))).to eq(75)
    ensure
      Syrus::PluginInvocation.runtime_health.reset!
    end

    it "includes external host API findings for the admin plugin page" do
      finding = Syrus::PluginHostSurface::Scanner::Finding.new(
        constant: "InternalService", tier: "unlisted", path: "lib/external.rb", line: 7
      )
      scan = Syrus::PluginHostSurface::Scanner::Result.new(public: [], unlisted: [ finding ], dynamic: [],
        minimum_syrus_version: nil, content_hash: "digest", error: nil)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "external_scan", version: "1.0.0", external: true,
        plugin_host_surface_scan: scan)
      admin = Factories.user(admin: true)
      sign_in_as(admin)

      get "/api/v1/app/admin/plugins/external_scan"

      expect(response.parsed_body.dig("plugin", "health", "state")).to eq("warning")
      expect(response.parsed_body.dig("plugin", "health", "host_surface", "unlisted", 0)).to include(
        "constant" => "InternalService", "path" => "lib/external.rb", "line" => 7
      )
    end

    it "serializes dynamic host API findings for the admin plugin page" do
      finding = Syrus::PluginHostSurface::Scanner::StringFinding.new(
        constant: "Job", tier: "dynamic", path: "lib/external.rb", line: 9, method: "class_name"
      )
      scan = Syrus::PluginHostSurface::Scanner::Result.new(public: [], unlisted: [], dynamic: [ finding ],
        minimum_syrus_version: nil, content_hash: "digest", error: nil)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "external_dynamic_scan", version: "1.0.0", external: true,
        plugin_host_surface_scan: scan)
      sign_in_as(Factories.user(admin: true))

      get "/api/v1/app/admin/plugins/external_dynamic_scan"

      expect(response.parsed_body.dig("plugin", "health", "host_surface", "dynamic", 0)).to include(
        "constant" => "Job", "method" => "class_name", "line" => 9
      )
    end

    it "reports runtime failures as degraded when the host API scan also warns" do
      provider = Class.new { include Syrus::Plugin::Callbacks }
      finding = Syrus::PluginHostSurface::Scanner::Finding.new(
        constant: "InternalService", tier: "unlisted", path: "lib/external.rb", line: 7
      )
      scan = Syrus::PluginHostSurface::Scanner::Result.new(public: [], unlisted: [ finding ], dynamic: [],
        minimum_syrus_version: nil, content_hash: "digest", error: nil)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "external_runtime_failure", version: "1.0.0", external: true,
        provides: { callbacks: provider }, plugin_host_surface_scan: scan)
      Syrus::PluginInvocation.call(
        extension_point: :callbacks, provider: provider, operation: :call,
        failure_threshold: 2, cooldown: 75, on_decline: nil
      ) { raise "provider unavailable" }
      sign_in_as(Factories.user(admin: true))

      get "/api/v1/app/admin/plugins/external_runtime_failure"

      expect(response.parsed_body.dig("plugin", "health", "state")).to eq("degraded")
      expect(response.parsed_body.dig("plugin", "health", "host_surface", "unlisted", 0)).to include(
        "constant" => "InternalService"
      )
      expect(response.parsed_body.dig("plugin", "health", "failures", 0)).to include(
        "extension_point" => "callbacks", "message" => "provider unavailable"
      )
    ensure
      Syrus::PluginInvocation.runtime_health.reset!
    end

    it "serializes conformance reasons and runtime failures in one health payload" do
      Syrus::Plugin::Family.define(:health_payload_spec) do
        shape :facet
        capability :detect, composition: :collect, absent: [], tier: :stable, context: "HealthContext"
      end
      namespace = Object.const_set(:HealthPayloadSpec, Module.new)
      provider = namespace.const_set(:Provider, Class.new do
        include Syrus::Plugin::Callbacks
        def self.key = :health_payload
        def self.display_name = "Health payload"
      end)
      declaration = Syrus::Plugin::FamilyDeclaration.build(
        family: :health_payload_spec, provider: "HealthPayloadSpec::Provider", implements: %i[detect]
      )
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "combined-health-plugin", version: "1.0.0", provides: { callbacks: provider },
        family_provides: [ declaration ]
      )
      Syrus::PluginInvocation.call(
        extension_point: :callbacks, provider:, operation: :call, on_decline: nil
      ) { raise "runtime failure" }
      sign_in_as(Factories.user(admin: true))

      get "/api/v1/app/admin/plugins"

      health = response.parsed_body.fetch("plugins").find { |plugin| plugin["name"] == "combined-health-plugin" }.fetch("health")
      expect(health).to include("state" => "non_conforming")
      expect(health.fetch("reasons")).to include("HealthPayloadSpec::Provider does not define required method detect")
      expect(health.fetch("failures").sole).to include(
        "source" => "runtime", "code" => "runtime_failure",
          "extension_point" => "callbacks", "operation" => "call", "message" => "runtime failure"
      )
    ensure
      Syrus::PluginInvocation.runtime_health.reset!
      Syrus::Plugin::Family.restore_built_ins!
      Object.send(:remove_const, :HealthPayloadSpec) if Object.const_defined?(:HealthPayloadSpec)
    end

    it "reports ok for a plugin with satisfied dependencies" do
      admin = Factories.user(admin: true)
      sign_in_as(admin)

      get "/api/v1/app/admin/plugins"

      entry = response.parsed_body["plugins"].find { |p| p["name"] == "github_source" }
      expect(entry["health"]).to include(
        "state" => "ok", "reasons" => [], "request_count" => 0, "last_error_at" => nil
      )
      expect(entry.dig("health", "jobs")).to include(
        "queue" => "plugin_github_source", "depth" => 0, "failed_count" => 0, "discarded_count" => 0
      )
    end

    it "reports the unmet dependency for a degraded plugin" do
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "needs_absent", version: "1.0.0", depends_on: [ "absent_plugin" ]
      )
      admin = Factories.user(admin: true)
      sign_in_as(admin)

      get "/api/v1/app/admin/plugins"

      entry = response.parsed_body["plugins"].find { |p| p["name"] == "needs_absent" }
      expect(entry["health"]["state"]).to eq("degraded")
      expect(entry["health"]["reasons"]).to include("requires absent_plugin, which is not installed")
    end

    it "reports an isolated load failure with its message" do
      Syrus::PluginRegistry.record_load_failure(
        name: "broken_external", state: :failed,
        message: "SyntaxError: unexpected end-of-input", backtrace: [ "/plugins/broken/lib/broken.rb:4" ]
      )
      admin = Factories.user(admin: true)
      sign_in_as(admin)

      get "/api/v1/app/admin/plugins"

      entry = response.parsed_body["plugins"].find { |plugin| plugin["name"] == "broken_external" }
      expect(entry["health"]).to include(
        "state" => "failed", "reasons" => [ "SyntaxError: unexpected end-of-input" ],
        "request_count" => 0, "last_error_at" => nil
      )
    end
  end

  describe "enable-me recommendations" do
    after { Syrus::PluginRecommendations.deregister("suggestible") }

    def register_suggestible!(enabled:)
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "suggestible", version: "1.0.0", provides: {})
      PluginRecord.find_by!(name: "suggestible").update!(enabled: enabled)
      Syrus::PluginRecommendations.register(
        plugin: "suggestible", reason: "Two of your repositories look like this.", block: ->(_s) { %w[a/b c/d] }
      )
    end

    def suggestible_entry
      sign_in_as(admin)
      get "/api/v1/app/admin/plugins"
      response.parsed_body["plugins"].find { |plugin| plugin["name"] == "suggestible" }
    end

    it "tells the admin why a disabled plugin might be worth turning on" do
      register_suggestible!(enabled: false)

      expect(suggestible_entry["recommendation"]).to eq(
        "reason" => "Two of your repositories look like this.", "evidence" => "a/b, c/d"
      )
    end

    it "says nothing about a plugin the admin has already enabled" do
      register_suggestible!(enabled: true)

      expect(suggestible_entry["recommendation"]).to be_nil
    end
  end
end
