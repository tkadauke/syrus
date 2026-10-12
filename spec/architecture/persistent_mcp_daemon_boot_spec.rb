require "rails_helper"

RSpec.describe "persistent MCP daemon worker boot" do
  subject(:initializer) { Rails.root.join("config/initializers/persistent_mcp_daemon.rb").read }

  it "prewarms the daemon before a worker accepts agent runs" do
    expect(initializer).to include('SyrusVersion.role == "worker"')
    expect(initializer).to include("Feature.persistent_mcp_sidecar_enabled?")
    expect(initializer).to include("PersistentMcpDaemon.ensure_started")
    expect(initializer).to include("daemon&.health_check")
  end
end
