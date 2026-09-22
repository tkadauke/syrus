require "rails_helper"

RSpec.describe "API: admin plugin services", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:manager) { "http://plugin-runtime:8080" }
  let(:configuration) { PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => manager, "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t" * 32) }
  let(:provider) do
    Class.new do
      def self.service_name = "git-mirror"
      def self.service_spec = { image: "ghcr.io/tkadauke/syrus-plugin-git-mirror:1", internal_port: 8080 }
    end
  end

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true)
    allow(PluginRuntime).to receive(:enabled?).and_return(true)
    allow(PluginRuntime::Configuration).to receive(:current).and_return(configuration)
    allow(PluginRuntime::DesiredServices).to receive(:all)
      .and_return([ PluginRuntime::DesiredServices::Entry.new(name: "git-mirror", plugin: "git_mirror", provider: provider) ])
  end

  def json = JSON.parse(response.body)

  it "lists plugin services with their live state and the actions that apply" do
    stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [
      { service: "git-mirror", plugin: "git_mirror", state: "running", endpoint: "http://git-mirror:8080", container_id: "abc" },
      { service: "leftover", plugin: "old_plugin", state: "running", container_id: "def" }
    ] }.to_json)
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services"

    expect(response).to have_http_status(:ok)
    expect(json).to include("mode" => "managed", "manageable" => true, "manager_error" => nil)
    mirror, leftover = json["services"]
    expect(mirror).to include("service" => "git-mirror", "state" => "running", "desired" => true, "held" => false,
                              "actions" => %w[stop restart logs])
    expect(leftover).to include("service" => "leftover", "desired" => false, "actions" => [])
  end

  it "falls back to the last reconcile's view when the manager is unreachable" do
    stub_request(:get, "#{manager}/v1/services").to_raise(Errno::ECONNREFUSED)
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services"

    expect(json["manager_error"]).to match(/unreachable/)
    expect(json["services"].sole).to include("service" => "git-mirror", "state" => "pending")
  end

  it "stops a service and returns its status" do
    stub_request(:post, "#{manager}/v1/services/git-mirror/stop")
      .to_return(status: 200, body: { service: "git-mirror", state: "stopped" }.to_json)
    sign_in_as(admin)

    post "/api/v1/app/admin/plugin_services/git-mirror/stop"

    expect(response).to have_http_status(:ok)
    expect(json.dig("service", "state")).to eq("stopped")
    expect(PluginRuntime::Holds).to be_held("git-mirror")
  end

  it "returns logs" do
    stub_request(:get, "#{manager}/v1/services/git-mirror/logs?tail=100")
      .to_return(status: 200, body: "GET /v1/repositories 200\n")
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services/git-mirror/logs", params: { tail: 100 }

    expect(json).to eq("service" => "git-mirror", "logs" => "GET /v1/repositories 200\n")
  end

  it "answers 404 for a service no plugin provides and 503 when the manager is down" do
    sign_in_as(admin)
    post "/api/v1/app/admin/plugin_services/nope/restart"
    expect(response).to have_http_status(:not_found)

    stub_request(:post, "#{manager}/v1/services/git-mirror/restart").to_raise(Errno::ECONNREFUSED)
    post "/api/v1/app/admin/plugin_services/git-mirror/restart"
    expect(response).to have_http_status(:service_unavailable)
    expect(json.dig("error", "code")).to eq("runtime_unavailable")
  end

  it "refuses actions when services are managed outside Syrus" do
    allow(PluginRuntime::Configuration).to receive(:current).and_return(PluginRuntime::Configuration.new({}))
    sign_in_as(admin)

    post "/api/v1/app/admin/plugin_services/git-mirror/stop"

    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "code")).to eq("not_managed")
  end

  it "is admin-only" do
    admin # the first user created is promoted to admin; this one must not be
    sign_in_as(Factories.user(admin: false))

    get "/api/v1/app/admin/plugin_services"

    expect(response).to have_http_status(:forbidden)
    expect(json.dig("error", "code")).to eq("forbidden")
  end
end
