require "rails_helper"

RSpec.describe "API: /api/v1/app/sidebar_pages", type: :request do
  let(:user) { Factories.user }

  def parse_body = JSON.parse(response.body)

  after { Syrus::PluginRegistry.reset! }

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/sidebar_pages"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns sidebar pages from enabled plugins for any signed-in user" do
    sign_in_as(user)
    Syrus::PluginRegistry.reset!
    page_provider = Class.new do
      include Syrus::Plugin::SidebarPage

      def self.sidebar_pages
        [
          {
            id: "spending.dashboard",
            label: "Spending",
            label_key: "spending:nav_spending",
            path: "/insights/spending",
            paths: [ "/insights/spending" ],
            component: "spending/Spending",
            icon: "spending",
            smart_folder_api_path: "/api/v1/app/spending",
            smart_folder_subject: "spending.record",
            order: 50
          }
        ]
      end
    end
    Syrus::PluginRegistry.register(name: "spending-plugin", version: "0.1.0", provides: { sidebar_page: page_provider })

    get "/api/v1/app/sidebar_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("pages")).to contain_exactly(
      include(
        "id" => "spending.dashboard",
        "label" => "Spending",
        "label_key" => "spending:nav_spending",
        "path" => "/insights/spending",
        "paths" => [ "/insights/spending" ],
        "component" => "spending/Spending",
        "icon" => "spending",
        "smart_folder_api_path" => "/api/v1/app/spending",
        "smart_folder_subject" => "spending.record",
        "order" => 50
      )
    )
  end

  it "orders pages by declared order, falling back to provider-registration order" do
    sign_in_as(user)
    Syrus::PluginRegistry.reset!
    first_provider = Class.new do
      include Syrus::Plugin::SidebarPage
      def self.sidebar_pages = [ { id: "first", label: "First", path: "/first", order: 10 } ]
    end
    second_provider = Class.new do
      include Syrus::Plugin::SidebarPage
      def self.sidebar_pages = [ { id: "second", label: "Second", path: "/second", order: 10 } ]
    end
    Syrus::PluginRegistry.register(name: "first-plugin", version: "0.1.0", provides: { sidebar_page: first_provider })
    Syrus::PluginRegistry.register(name: "second-plugin", version: "0.1.0", provides: { sidebar_page: second_provider })

    get "/api/v1/app/sidebar_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("pages").map { |page| page.fetch("id") }).to eq(%w[ first second ])
  end

  it "omits sidebar pages from disabled plugins" do
    sign_in_as(user)
    Syrus::PluginRegistry.reset!
    page_provider = Class.new do
      include Syrus::Plugin::SidebarPage
      def self.sidebar_pages = [ { id: "hidden", label: "Hidden", path: "/hidden" } ]
    end
    Syrus::PluginRegistry.register(name: "sidebar-plugin", version: "0.1.0", provides: { sidebar_page: page_provider })
    PluginRecord.find_by!(name: "sidebar-plugin").update!(enabled: false)

    get "/api/v1/app/sidebar_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("pages" => [])
  end

  it "treats a freshly-registered default-enabled plugin as enabled with no prior PluginRecord row" do
    sign_in_as(user)
    Syrus::PluginRegistry.reset!
    page_provider = Class.new do
      include Syrus::Plugin::SidebarPage
      def self.sidebar_pages = [ { id: "fresh", label: "Fresh", path: "/fresh" } ]
    end

    expect(PluginRecord.where(name: "fresh-plugin")).not_to exist
    Syrus::PluginRegistry.register(name: "fresh-plugin", version: "0.1.0", default_enabled: true, provides: { sidebar_page: page_provider })

    get "/api/v1/app/sidebar_pages"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("pages").map { |page| page.fetch("id") }).to include("fresh")
  end
end
