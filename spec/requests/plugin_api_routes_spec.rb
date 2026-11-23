require "rails_helper"

module Api
  module V1
    module App
      class PluginApiRouteFixtureRaisingController < BaseController
        def show
          raise(params[:failure].presence || "fixture route failed")
        end
      end

      class PluginApiRouteFixtureHealthyController < BaseController
        def show
          render json: { status: "ok" }
        end
      end
    end
  end
end

RSpec.describe "Plugin API routes", type: :request do
  before do
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "raising_route_fixture",
      version: "1.0.0",
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/raising-route-fixture",
          controller: "api/v1/app/plugin_api_route_fixture_raising#show"
        }
      ]
    )
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "healthy_route_fixture",
      version: "1.0.0",
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/healthy-route-fixture",
          controller: "api/v1/app/plugin_api_route_fixture_healthy#show"
        }
      ]
    )
    sign_in_as(Factories.user)
  end

  after { Syrus::PluginInvocation.runtime_health.reset! }

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
    expect(Rails.application.routes.recognize_path("/api/v1/app/linear/teams", method: :post)).to include(
      controller: "api/v1/app/plugin_routes",
      action: "show"
    )
  end

  it "isolates a production route failure with the structured API error shape" do
    allow(Rails.env).to receive(:production?).and_return(true)

    get "/api/v1/app/raising-route-fixture"

    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body).to eq(
      "v" => 1,
      "error" => {
        "code" => "plugin_route_failed",
        "message" => "The raising_route_fixture plugin could not complete this request.",
        "plugin" => "raising_route_fixture"
      }
    )
  end

  it "leaves route failures to core exception handling outside production" do
    allow(Rails.env).to receive(:production?).and_return(false)

    get "/api/v1/app/raising-route-fixture"

    expect(response.body).to include('window.location = "/500.html"')
    expect(PluginRecord.find_by!(name: "raising_route_fixture")).to have_attributes(
      request_count: 1,
      last_error_at: nil
    )
    expect(Syrus::PluginInvocation.runtime_health.failures(plugin: "raising_route_fixture")).to be_empty
  end

  it "records requests and the latest production failure in plugin health" do
    allow(Rails.env).to receive(:production?).and_return(true)

    get "/api/v1/app/raising-route-fixture"

    record = PluginRecord.find_by!(name: "raising_route_fixture")
    expect(record).to have_attributes(request_count: 1)
    expect(record.last_error_at).to be_within(2.seconds).of(Time.current)
    failure = Syrus::PluginInvocation.runtime_health.failures(plugin: record.name).sole
    expect(failure).to have_attributes(
      extension_point: "route",
      operation: "dispatch",
      exception_class: "RuntimeError",
      message: "fixture route failed",
      count: 1
    )
    health = Admin::PluginsPayload.new.show(record.name).dig(:plugin, :health)
    expect(health).to include(
      state: "degraded",
      request_count: 1,
      last_error_at: record.last_error_at.iso8601
    )
    expect(health.fetch(:jobs)).to include(
      queue: "plugin_raising_route_fixture",
      depth: 0,
      failed_count: 0,
      discarded_count: 0
    )
    expect(Syrus::PluginInvocation.runtime_health.circuits(plugin: record.name)).to be_empty
  end

  it "rate-limits persistent last-error writes while aggregating failures" do
    allow(Rails.env).to receive(:production?).and_return(true)

    travel_to(Time.current.change(usec: 0)) do
      get "/api/v1/app/raising-route-fixture"
      first_error_at = PluginRecord.find_by!(name: "raising_route_fixture").last_error_at

      travel 30.seconds
      get "/api/v1/app/raising-route-fixture"

      record = PluginRecord.find_by!(name: "raising_route_fixture")
      expect(record).to have_attributes(request_count: 2, last_error_at: first_error_at)
      expect(Syrus::PluginInvocation.runtime_health.failures(plugin: record.name).sole.count).to eq(2)
    end
  end

  it "bounds distinct route failures in runtime health and the admin payload" do
    allow(Rails.env).to receive(:production?).and_return(true)
    bounded_health = Syrus::PluginRuntimeHealth.new(max_failures_per_plugin: 2)
    Syrus::PluginInvocation.runtime_health = bounded_health

    3.times { |index| get "/api/v1/app/raising-route-fixture", params: { failure: "failure #{index}" } }

    failures = bounded_health.failures(plugin: "raising_route_fixture")
    expect(failures.map(&:message)).to contain_exactly("failure 1", "failure 2")

    payload_failures = Admin::PluginsPayload.new
      .show("raising_route_fixture")
      .dig(:plugin, :health, :failures)
    expect(payload_failures.map { |failure| failure.fetch(:message) }).to contain_exactly("failure 1", "failure 2")
  end

  it "leaves a healthy sibling plugin available after a route failure" do
    allow(Rails.env).to receive(:production?).and_return(true)

    get "/api/v1/app/raising-route-fixture"
    get "/api/v1/app/healthy-route-fixture"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("v" => 1, "status" => "ok")
    expect(PluginRecord.find_by!(name: "healthy_route_fixture")).to have_attributes(
      request_count: 1,
      last_error_at: nil
    )
  end
end
