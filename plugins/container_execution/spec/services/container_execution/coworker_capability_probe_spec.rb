require "rails_helper"

RSpec.describe ContainerExecution::CoworkerCapabilityProbe do
  around do |example|
    previous_env = ENV.to_h
    example.run
  ensure
    ENV.replace(previous_env)
  end

  it "advertises confinement only when the complete fail-closed configuration is present" do
    allow(ContainerExecution::Configuration).to receive(:docker_command_path).and_return("/usr/bin/docker")
    allow(ContainerExecution::Configuration).to receive(:docker_transport_available?).and_return(true)
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "ghcr.io/example/coworker:latest"
    ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "/run/syrus/mcp.sock"
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "/run/syrus=/host/run/syrus"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = "coworker-egress"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "10.0.0.53"
    %w[CODEX CLAUDE MUSE AGY].each { |provider| ENV["SYRUS_CONTAINER_EXECUTION_#{provider}_PROXY"] = "http://proxy:8080" }

    expect(described_class.capability_probes.first).to include(dimension: "runtime", token: "confined_coworker")

    ENV.delete("SYRUS_CONTAINER_EXECUTION_CODEX_PROXY")
    expect(described_class.capability_probes).to be_empty
  end
end
