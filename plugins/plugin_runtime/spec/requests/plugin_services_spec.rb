require "rails_helper"

RSpec.describe "API: admin plugin services", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:manager) { "http://plugin-runtime:8080" }
  let(:configuration) { PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => manager, "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t" * 32) }
  let(:provider) do
    Class.new do
      def self.service_name = "git-mirror"
      def self.service_spec = { image: "ghcr.io/tkadauke/syrus-plugin-git-mirror:1", internal_port: 8080 }
      def self.service_details(endpoint:) = { summary: [ { label_key: "git_mirror:details.repositories", value: 1, format: "number" } ], endpoint: endpoint }
    end
  end

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true)
    allow(PluginRuntime).to receive(:enabled?).and_return(true)
    allow(PluginRuntime::Configuration).to receive(:current).and_return(configuration)
    allow(PluginRuntime::DesiredServices).to receive(:all)
      .and_return([ PluginRuntime::DesiredServices::Entry.new(name: "git-mirror", plugin: "git_mirror", provider: provider) ])
    stub_request(:get, "#{manager}/v1/volumes").to_return(status: 200, body: { volumes: [] }.to_json)
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
                              "actions" => %w[stop restart logs details])
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

  it "lists stored data and deletes what no running service uses" do
    stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [] }.to_json)
    stub_request(:get, "#{manager}/v1/volumes").to_return(status: 200, body: { volumes: [
      { name: "syrus_plugin_old_data", service: "old", plugin: "old_plugin", in_use: false, size_bytes: 4096 }
    ] }.to_json)
    remove = stub_request(:delete, "#{manager}/v1/volumes/syrus_plugin_old_data").to_return(status: 204, body: "")
    stub_request(:delete, "#{manager}/v1/volumes/syrus_plugin_git-mirror_data").to_return(status: 409, body: { error: "in use" }.to_json)
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services"
    expect(json["volumes"].sole).to include("name" => "syrus_plugin_old_data", "in_use" => false, "size_bytes" => 4096)

    delete "/api/v1/app/admin/plugin_services/volumes/syrus_plugin_old_data"
    expect(response).to have_http_status(:no_content)
    expect(remove).to have_been_requested

    delete "/api/v1/app/admin/plugin_services/volumes/syrus_plugin_git-mirror_data"
    expect(response).to have_http_status(:conflict)
    expect(json.dig("error", "code")).to eq("volume_in_use")
  end

  it "returns what a running service says about itself" do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return("http://git-mirror:8080")
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services/git-mirror/details"

    expect(response).to have_http_status(:ok)
    expect(json.dig("details", "summary", 0, "value")).to eq(1)
    expect(json.dig("details", "endpoint")).to eq("http://git-mirror:8080")
  end

  it "answers 503 for details while the service is not answering" do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("git-mirror").and_return(nil)
    sign_in_as(admin)

    get "/api/v1/app/admin/plugin_services/git-mirror/details"

    expect(response).to have_http_status(:service_unavailable)
  end

  it "is admin-only" do
    admin # the first user created is promoted to admin; this one must not be
    sign_in_as(Factories.user(admin: false))

    get "/api/v1/app/admin/plugin_services"

    expect(response).to have_http_status(:forbidden)
    expect(json.dig("error", "code")).to eq("forbidden")
  end
end
