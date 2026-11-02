require "rails_helper"
require "open3"

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

  it "fails verification when the root is writable or direct egress succeeds" do
    harness = <<~BASH
      id() { echo 1000; }
      touch() { [ "${ROOT_WRITABLE:-false}" = true ]; }
      timeout() {
        case "${6:-}:${4:-}" in
          proxy:*) return 0 ;;
          *1.1.1.1/443*) [ "${PUBLIC_EGRESS:-false}" = true ] ;;
          *169.254.169.254/80*) return 1 ;;
          *) return 1 ;;
        esac
      }
      #{described_class::PROBE_SCRIPT}
    BASH
    proxy_arguments = [ "proxy", "8080" ] * described_class::PROVIDERS.length

    writable_root = Open3.capture3(
      { "ROOT_WRITABLE" => "true", "PUBLIC_EGRESS" => "false" },
      "bash", "-c", harness, "probe", *proxy_arguments
    ).last
    open_egress = Open3.capture3(
      { "ROOT_WRITABLE" => "false", "PUBLIC_EGRESS" => "true" },
      "bash", "-c", harness, "probe", *proxy_arguments
    ).last
    confined = Open3.capture3(
      { "ROOT_WRITABLE" => "false", "PUBLIC_EGRESS" => "false" },
      "bash", "-c", harness, "probe", *proxy_arguments
    ).last

    expect(writable_root).not_to be_success
    expect(open_egress).not_to be_success
    expect(confined).to be_success
  end
end
