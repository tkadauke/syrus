require "rails_helper"

RSpec.describe ContainerExecution::CoworkerCapabilityProbe do
  around do |example|
    previous_env = ENV.to_h
    example.run
  ensure
    ENV.replace(previous_env)
  end

  it "runs the per-turn container and default-deny checks before advertising confinement" do
    allow(ContainerExecution::Configuration).to receive(:docker_command_path).and_return("/usr/bin/docker")
    allow(ContainerExecution::Configuration).to receive(:docker_transport_available?).and_return(true)
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "ghcr.io/example/coworker:latest"
    ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "/run/syrus/mcp.sock"
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "/run/syrus=/host/run/syrus"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = "coworker-egress"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "10.0.0.53"
    %w[CODEX CLAUDE MUSE AGY].each { |provider| ENV["SYRUS_CONTAINER_EXECUTION_#{provider}_PROXY"] = "http://proxy:8080" }

    probe = described_class.capability_probes.first
    expect(probe).to include(
      dimension: "runtime", token: "confined_coworker", timeout: 30,
      diagnostics: include(
        "confined_coworker_configuration" => "complete",
        "confined_coworker_missing_settings" => []
      )
    )
    expect(probe.fetch(:command)).to include(
      "/usr/bin/docker", "run", "--rm", "--read-only", "--cap-drop", "ALL",
      "--network", "coworker-egress", "--dns", "10.0.0.53"
    )
    expect(probe.fetch(:command).join(" ")).to include("1.1.1.1/443", "169.254.169.254/80")

    ENV.delete("SYRUS_CONTAINER_EXECUTION_CODEX_PROXY")
    probe = described_class.capability_probes.first
    expect(probe.dig(:diagnostics, "confined_coworker_configuration")).to eq("missing")
    expect(probe.dig(:diagnostics, "confined_coworker_missing_settings")).to include("codex_proxy")
    expect(probe.fetch(:command).first).to eq(RbConfig.ruby)
  end
end
