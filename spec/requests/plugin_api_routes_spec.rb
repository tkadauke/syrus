require "rails_helper"

RSpec.describe "Plugin API routes", type: :request do
  def plugin_api_routes
    Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      Array(metadata[:routes]).filter_map do |raw_route|
        route = raw_route.to_h.with_indifferent_access
        path = route[:path].to_s
        next unless path.start_with?("/api/")

        {
          verb: route[:verb].presence || "GET",
          path: path,
          controller: route[:controller].to_s
        }
      end
    end
  end

  it "recognizes every installed plugin API route" do
    plugin_api_routes.each do |route|
      recognized = Rails.application.routes.recognize_path(route[:path], method: route[:verb].to_s.downcase.to_sym)

      expected_controllers = [
        "api/v1/app/plugin_routes",
        "api/v1/admin/plugin_routes",
        route[:controller].split("#").first
      ]
      expect(expected_controllers).to include(recognized[:controller])
    end
  end

  it "points plugin API route metadata at existing controller actions" do
    plugin_api_routes.each do |route|
      controller_path, action = route[:controller].split("#", 2)
      controller = "#{controller_path.camelize}Controller".constantize

      expect(controller.action_methods).to include(action)
    end
  end

  it "routes plugin-owned app API endpoints through the plugin dispatcher", requires_plugin: "linear_source" do
    expect(Rails.application.routes.recognize_path("/api/v1/app/linear/teams", method: :get)).to include(
      controller: "api/v1/app/plugin_routes",
      action: "show"
    )
  end
end
