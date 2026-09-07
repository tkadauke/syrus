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
end
