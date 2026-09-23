require "rails_helper"

# Tailscale has no lifecycle API of its own -- enable/disable/restart go
# through Plugin Runtime's shared Admin -> Plugin Services surface (see
# plugins/plugin_runtime/spec/requests/plugin_services_spec.rb for that
# generic contract, exercised there with a fake provider). This spec drives
# the same endpoints with the *real* tailscale plugin and
# Tailscale::RuntimeService wired in, so the privileged-lane integration
# (DesiredPrivilegedServices, ManagedDriver#ensure_privileged_one, the
# "Privileged" badge) is covered end to end for the operator flows described
# in plugins/tailscale/docs/syrus_docs/tailscale.md.
RSpec.describe "API: admin plugin services for Tailscale", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:manager) { "http://plugin-runtime:8080" }
  let(:managed_configuration) do
    PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => manager, "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t" * 32)
  end

  def json = JSON.parse(response.body)
  def tailscale_row = json["services"].find { |service| service["service"] == "tailscale" }

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true)
    PluginRecord.find_by!(name: "tailscale").update!(enabled: true)
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "auth_key").and_return("tskey-auth-abc123")
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "hostname").and_return(nil)
    allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "exit_node").and_return(false)
    allow(PluginRuntime::Configuration).to receive(:current).and_return(managed_configuration)
    stub_request(:get, "#{manager}/v1/volumes").to_return(status: 200, body: { volumes: [] }.to_json)
    sign_in_as(admin)
  end

  describe "status: enabled and running" do
    it "lists tailscale with the privileged badge and stop/restart actions" do
      stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [
        { service: "tailscale", plugin: "tailscale", state: "running", endpoint: "http://tailscale:8080",
          container_id: "abc", privileged: true }
      ] }.to_json)

      get "/api/v1/app/admin/plugin_services"

      expect(response).to have_http_status(:ok)
      expect(tailscale_row).to include("service" => "tailscale", "state" => "running", "privileged" => true,
                                       "desired" => true, "held" => false, "actions" => %w[stop restart logs])
    end
  end

  describe "status: service unhealthy" do
    it "still surfaces stop/restart so an operator can recycle a failing container" do
      stub_request(:get, "#{manager}/v1/services").to_return(status: 200, body: { services: [
        { service: "tailscale", plugin: "tailscale", state: "unhealthy", endpoint: "http://tailscale:8080",
          container_id: "abc", privileged: true, error: "healthcheck failing" }
      ] }.to_json)

      get "/api/v1/app/admin/plugin_services"

      expect(tailscale_row).to include("state" => "unhealthy", "error" => "healthcheck failing",
                                       "actions" => %w[stop restart logs])
    end
  end

  describe "disable: stop" do
    it "stops the container and holds it so the next reconcile leaves it alone" do
      stub_request(:post, "#{manager}/v1/services/tailscale/stop")
        .to_return(status: 200, body: { service: "tailscale", state: "stopped" }.to_json)

      post "/api/v1/app/admin/plugin_services/tailscale/stop"

      expect(response).to have_http_status(:ok)
      expect(json.dig("service", "state")).to eq("stopped")
      expect(PluginRuntime::Holds).to be_held("tailscale")
    end
  end

  describe "enable: start" do
    it "releases the hold and ensures the privileged container with the configured env" do
      ensure_request = stub_request(:put, "#{manager}/v1/privileged/tailscale")
        .with(body: { env: { "TS_AUTHKEY" => "tskey-auth-abc123" } }.to_json)
        .to_return(status: 200, body: { service: "tailscale", state: "starting", privileged: true }.to_json)
      PluginRuntime::Holds.hold!("tailscale")

      post "/api/v1/app/admin/plugin_services/tailscale/start"

      expect(response).to have_http_status(:ok)
      expect(json.dig("service", "state")).to eq("starting")
      expect(ensure_request).to have_been_requested
      expect(PluginRuntime::Holds).not_to be_held("tailscale")
    end

    it "reports an error status instead of asking the manager, when no auth key is configured" do
      allow(Syrus::PluginSettings).to receive(:get).with("tailscale", "auth_key").and_return(nil)

      post "/api/v1/app/admin/plugin_services/tailscale/start"

      expect(response).to have_http_status(:ok)
      expect(json.dig("service", "state")).to eq("error")
      expect(json.dig("service", "error")).to match(/TS_AUTHKEY is not configured/)
    end
  end

  describe "restart" do
    it "restarts the running container" do
      stub_request(:post, "#{manager}/v1/services/tailscale/restart")
        .to_return(status: 200, body: { service: "tailscale", state: "starting", privileged: true }.to_json)

      post "/api/v1/app/admin/plugin_services/tailscale/restart"

      expect(response).to have_http_status(:ok)
      expect(json.dig("service", "state")).to eq("starting")
    end
  end

  describe "missing runtime: Plugin Runtime plugin disabled" do
    it "404s every plugin_services action before even asking the manager" do
      PluginRecord.find_by!(name: "plugin_runtime").update!(enabled: false)

      get "/api/v1/app/admin/plugin_services"

      expect(response).to have_http_status(:not_found)
      expect(json.dig("error", "code")).to eq("plugin_disabled")
    end
  end

  describe "missing runtime: manager unreachable" do
    it "falls back to a pending row and reports the manager error, without tearing tailscale down" do
      stub_request(:get, "#{manager}/v1/services").to_raise(Errno::ECONNREFUSED)

      get "/api/v1/app/admin/plugin_services"

      expect(response).to have_http_status(:ok)
      expect(json["manager_error"]).to match(/unreachable/)
      expect(tailscale_row).to include("service" => "tailscale", "state" => "pending")
    end

    it "answers 503 runtime_unavailable for an action while the manager is down" do
      stub_request(:post, "#{manager}/v1/services/tailscale/restart").to_raise(Errno::ECONNREFUSED)

      post "/api/v1/app/admin/plugin_services/tailscale/restart"

      expect(response).to have_http_status(:service_unavailable)
      expect(json.dig("error", "code")).to eq("runtime_unavailable")
    end
  end
end
