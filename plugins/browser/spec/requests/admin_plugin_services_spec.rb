require "rails_helper"

# The Plugin Services admin page is entirely generic (PluginRuntime::AdminPayload
# reads whatever "plugin_runtime:service" providers are registered), so nothing
# Browser-specific is needed for it to work at all -- SyrusBrowser::RuntimeService
# implementing the two required Service methods (see runtime_service_spec.rb) is
# the whole contract. This spec exercises that generic page against Browser's
# real registration (not a fake provider, as plugin_runtime's own request spec
# uses) to prove two things the issue asks for explicitly:
#
#   1. status/logs are diagnosable for the real browser service -- an admin can
#      see why it is failing without shelling into a worker.
#   2. "details" never appears for it, because SyrusBrowser::RuntimeService
#      deliberately implements no service_details (see its class comment: the
#      service holds no session state to summarize). That omission is what
#      keeps live browser session content (URLs navigated, page snapshots,
#      screenshots) out of the admin page entirely, so it is worth locking in
#      with a test rather than leaving it as an accident of an unimplemented
#      method.
RSpec.describe "API: admin plugin services (browser)", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:manager) { "http://plugin-runtime:8080" }

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true)
    ENV["SYRUS_PLUGIN_RUNTIME_URL"] = manager
    ENV["SYRUS_PLUGIN_RUNTIME_TOKEN"] = "t" * 32
    stub_request(:get, "#{manager}/v1/volumes").to_return(status: 200, body: { volumes: [] }.to_json)
    sign_in_as(admin)
  end

  after do
    ENV.delete("SYRUS_PLUGIN_RUNTIME_URL")
    ENV.delete("SYRUS_PLUGIN_RUNTIME_TOKEN")
  end

  def json = JSON.parse(response.body)

  it "lists the real browser service with status/logs but never a details action" do
    stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [
      { service: "browser", plugin: "browser", state: "running", endpoint: "http://browser:8080", image: "ghcr.io/tkadauke/syrus-plugin-browser:latest", container_id: "abc" }
    ] }.to_json)

    get "/api/v1/app/admin/plugin_services"

    expect(response).to have_http_status(:ok)
    browser = json["services"].find { |service| service["service"] == "browser" }
    expect(browser).to include("plugin" => "browser", "desired" => true, "state" => "running")
    expect(browser["actions"]).to include("stop", "restart", "logs")
    expect(browser["actions"]).not_to include("details")
  end

  it "surfaces an unhealthy browser service's failure reason without any session content" do
    stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [
      { service: "browser", plugin: "browser", state: "unhealthy", error: "GET /healthz: connection refused" }
    ] }.to_json)

    get "/api/v1/app/admin/plugin_services"

    browser = json["services"].find { |service| service["service"] == "browser" }
    expect(browser).to include("state" => "unhealthy", "error" => "GET /healthz: connection refused")
  end

  it "returns the browser container's logs for diagnosis" do
    stub_request(:get, "#{manager}/v1/services/browser/logs?tail=100")
      .to_return(status: 200, body: "starting playwright-mcp on :8080\nhealthz check ok\n")

    get "/api/v1/app/admin/plugin_services/browser/logs", params: { tail: 100 }

    expect(json).to eq("service" => "browser", "logs" => "starting playwright-mcp on :8080\nhealthz check ok\n")
  end

  it "answers not_found for browser's details panel, since the service reports none" do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("browser").and_return("http://browser:8080")

    get "/api/v1/app/admin/plugin_services/browser/details"

    expect(response).to have_http_status(:not_found)
    expect(json.dig("error", "code")).to eq("not_found")
  end

  it "restarts the browser service" do
    stub_request(:post, "#{manager}/v1/services/browser/restart")
      .to_return(status: 200, body: { service: "browser", state: "starting" }.to_json)

    post "/api/v1/app/admin/plugin_services/browser/restart"

    expect(response).to have_http_status(:ok)
    expect(json.dig("service", "state")).to eq("starting")
  end
end
