require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/plugin_pages", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) do
    admin
    Factories.user(admin: false)
  end

  def parse_body = JSON.parse(response.body)

  after { Syrus::PluginRegistry.reset! }

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns admin pages from enabled plugins" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    page_provider = Class.new do
      include Syrus::Plugin::AdminPage

      def self.admin_pages
        [
          {
            id: "dev.performance",
            label: "Performance",
            label_key: "dev:nav_performance",
            path: "/admin/performance",
            paths: [ "/admin/performance" ],
            component: "dev/AdminPerformance",
            order: 50,
            group_id: "observability"
          }
        ]
      end
    end
    Syrus::PluginRegistry.register(name: "page-plugin", version: "0.1.0", provides: { admin_page: page_provider })

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("pages")).to contain_exactly(
      include(
        "id" => "dev.performance",
        "label" => "Performance",
        "label_key" => "dev:nav_performance",
        "path" => "/admin/performance",
        "paths" => [ "/admin/performance" ],
        "component" => "dev/AdminPerformance",
        "order" => 50,
        "group_id" => "observability"
      )
    )
  end

  it "returns syrus_dev admin page metadata from the plugin contract" do
    sign_in_as(admin)
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(true)

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("pages")).to include(
      include(
        "id" => "syrus_dev.performance",
        "label_key" => "syrus_dev:nav_performance",
        "path" => "/admin/performance",
        "paths" => [ "/admin/performance" ],
        "component" => "syrus_dev/AdminPerformance",
        "group_id" => "observability"
      )
    )
  end

  it "omits the syrus_dev operational logs page while operational log indexing is disabled" do
    sign_in_as(admin)
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(false)

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:ok)
    page_ids = parse_body.fetch("pages").map { |page| page.fetch("id") }
    expect(page_ids).to include("syrus_dev.performance")
    expect(page_ids).not_to include("syrus_dev.operational_logs")
  end

  it "omits admin pages from disabled plugins" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    page_provider = Class.new do
      include Syrus::Plugin::AdminPage
      def self.admin_pages = [ { id: "hidden", label: "Hidden", path: "/admin/hidden" } ]
    end
    Syrus::PluginRegistry.register(name: "page-plugin", version: "0.1.0", provides: { admin_page: page_provider })
    PluginRecord.find_by!(name: "page-plugin").update!(enabled: false)

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("pages" => [])
  end
end
