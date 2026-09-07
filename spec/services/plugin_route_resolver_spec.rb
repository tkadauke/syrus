require "rails_helper"

RSpec.describe PluginRouteResolver do
  def register_plugin(name, routes)
    Syrus::PluginRegistry.register(
      name: name,
      version: "0.1.0",
      routes: routes,
      provides: {}
    )
  end

  after { Syrus::PluginRegistry.reset! }

  describe ".find / .match?" do
    it "finds a plugin-declared API route matching verb, path shape, and controller prefix" do
      register_plugin("widgets", [
        { verb: "GET", path: "/api/v1/app/admin/widgets/:id", controller: "api/v1/app/admin/widgets#show" }
      ])
      request = instance_double(ActionDispatch::Request, request_method: "GET", path: "/api/v1/app/admin/widgets/42")

      route = described_class.find(request, controller_prefix: "api/v1/app/")

      expect(route).not_to be_nil
      expect(route.controller).to eq("api/v1/app/admin/widgets#show")
      expect(route.params).to eq(id: "42")
      expect(described_class.match?(request, controller_prefix: "api/v1/app/")).to be true
    end

    it "does not match a route outside the given controller prefix" do
      register_plugin("widgets", [
        { verb: "GET", path: "/api/v1/admin/widgets/:id", controller: "api/v1/admin/widgets#show" }
      ])
      request = instance_double(ActionDispatch::Request, request_method: "GET", path: "/api/v1/admin/widgets/42")

      expect(described_class.match?(request, controller_prefix: "api/v1/app/")).to be false
    end

    it "does not match when the HTTP verb differs" do
      register_plugin("widgets", [
        { verb: "GET", path: "/api/v1/app/widgets", controller: "api/v1/app/widgets#index" }
      ])
      request = instance_double(ActionDispatch::Request, request_method: "POST", path: "/api/v1/app/widgets")

      expect(described_class.match?(request, controller_prefix: "api/v1/app/")).to be false
    end

    it "does not match routes from disabled plugins" do
      register_plugin("disabled_widgets", [
        { verb: "GET", path: "/api/v1/app/disabled_widgets", controller: "api/v1/app/disabled_widgets#index" }
      ])
      PluginRecord.find_by!(name: "disabled_widgets").update!(enabled: false)
      request = instance_double(ActionDispatch::Request, request_method: "GET", path: "/api/v1/app/disabled_widgets")

      expect(described_class.match?(request, controller_prefix: "api/v1/app/")).to be false
    end

    it "recognizes declared disabled API routes for wildcard routing" do
      register_plugin("disabled_widgets", [
        { verb: "GET", path: "/api/v1/app/disabled_widgets", controller: "api/v1/app/disabled_widgets#index" }
      ])
      PluginRecord.find_by!(name: "disabled_widgets").update!(enabled: false)
      request = instance_double(ActionDispatch::Request, request_method: "GET", path: "/api/v1/app/disabled_widgets")

      expect(described_class.declared_api_route?(request, controller_prefix: "api/v1/app/")).to be true
    end
  end

  describe ".spa_route_declared?" do
    it "matches a plugin-declared static spa#show path" do
      register_plugin("spa_widgets", [
        { verb: "GET", path: "/admin/spa_widgets", controller: "spa#show" }
      ])

      expect(described_class.spa_route_declared?("/admin/spa_widgets")).to be true
      expect(described_class.spa_route_declared?("/admin/other")).to be false
    end

    it "matches a plugin-declared spa#show path with a dynamic segment" do
      register_plugin("git_history", [
        { verb: "GET", path: "/repositories/:repository_id/plugin/git_history", controller: "spa#show" }
      ])

      expect(described_class.spa_route_declared?("/repositories/42/plugin/git_history")).to be true
      expect(described_class.spa_route_declared?("/repositories/42/plugin/other")).to be false
    end

    it "ignores non-spa#show routes" do
      register_plugin("widgets", [
        { verb: "GET", path: "/repositories/:repository_id/plugin/git_history", controller: "api/v1/app/git_history#show" }
      ])

      expect(described_class.spa_route_declared?("/repositories/42/plugin/git_history")).to be false
    end
  end

  describe ".sidebar_page_route?" do
    def register_sidebar_page(name, paths)
      provider = Class.new do
        include Syrus::Plugin::SidebarPage
      end
      provider.define_singleton_method(:sidebar_pages) { [ { id: name, label: name, paths: paths, component: "x" } ] }
      Syrus::PluginRegistry.register(name: name, version: "0.1.0", provides: { sidebar_page: provider })
    end

    it "matches a bare numeric id" do
      register_sidebar_page("widgets", [ "/widgets", "/widgets/:id" ])

      expect(described_class.sidebar_page_route?("/widgets/42")).to be true
    end

    # Regression: Mockups' detail path is "/mockups/:id", but the value the
    # frontend actually navigates to is a "MOCKUP-<id>" slug (Mockups::Mockup#slug),
    # not a bare Rails id -- so a hard reload of a real mockup detail URL 404ed
    # even though the plugin declared the path.
    it "matches a PREFIX-<digits> slug id, the same shape Mockups::Mockup#slug produces" do
      register_sidebar_page("mockups", [ "/mockups", "/mockups/:id" ])

      expect(described_class.sidebar_page_route?("/mockups/MOCKUP-1")).to be true
    end

    it "still rejects an unrelated static segment standing in for :id" do
      register_sidebar_page("scheduled_tasks", [ "/scheduled_tasks/:id" ])

      expect(described_class.sidebar_page_route?("/scheduled_tasks/legacy")).to be false
    end
  end

  describe ".repo_page_tab_route?" do
    def register_repo_page_tab(name, &block)
      provider = Class.new do
        include Syrus::Plugin::RepoPageTab
      end
      provider.define_singleton_method(:repo_page_tabs, &block)
      Syrus::PluginRegistry.register(name: name, version: "0.1.0", provides: { repo_page_tab: provider })
    end

    it "derives a valid SPA path from a repo_page_tab provider's own tab metadata, with no manual route declaration" do
      owner = Factories.user
      repository = Factories.repository(user: owner)
      register_repo_page_tab("widgets") do |repository:, user:|
        [ { id: "widgets.widgets", label: "Widgets", path: "/repositories/#{repository.id}/plugin/widgets" } ]
      end

      expect(described_class.repo_page_tab_route?("/repositories/#{repository.id}/plugin/widgets")).to be true
      expect(described_class.repo_page_tab_route?("/repositories/#{repository.id}/plugin/other")).to be false
    end

    it "resolves the tab for a repository member even when the probe uses the owner" do
      owner = Factories.user(email_address: "owner@example.com")
      repository = Factories.repository(user: owner)
      register_repo_page_tab("widgets") do |repository:, user:|
        [ { id: "widgets.widgets", label: "Widgets", path: "/repositories/#{repository.id}/plugin/widgets" } ]
      end

      expect(described_class.repo_page_tab_route?("/repositories/#{repository.id}/plugin/widgets")).to be true
    end

    it "returns false for a nonexistent repository" do
      register_repo_page_tab("widgets") do |repository:, user:|
        [ { id: "widgets.widgets", label: "Widgets", path: "/repositories/#{repository.id}/plugin/widgets" } ]
      end

      expect(described_class.repo_page_tab_route?("/repositories/999999999/plugin/widgets")).to be false
    end

    it "returns false when no repo_page_tab provider declares a matching path" do
      owner = Factories.user
      repository = Factories.repository(user: owner)

      expect(described_class.repo_page_tab_route?("/repositories/#{repository.id}/plugin/nonexistent")).to be false
    end

    it "returns false for paths outside the repositories/*/plugin/ shape" do
      expect(described_class.repo_page_tab_route?("/admin/mysql")).to be false
    end
  end
end
