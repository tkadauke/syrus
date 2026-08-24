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
  end

  describe ".spa_route_declared?" do
    it "matches a plugin-declared static spa#show path" do
      register_plugin("admin_mysql", [
        { verb: "GET", path: "/admin/mysql", controller: "spa#show" }
      ])

      expect(described_class.spa_route_declared?("/admin/mysql")).to be true
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
end
