require "rbconfig"
require "uri"

module ContainerExecution
  class CoworkerCapabilityProbe
    include Syrus::Plugin::WorkerCapabilityProbe

    RUNTIME_TOKEN = "confined_coworker".freeze
    PROVIDERS = %w[CODEX CLAUDE MUSE AGY].freeze
    PROBE_TIMEOUT_SECONDS = 30
    PROBE_SCRIPT = <<~'BASH'.freeze
      set -euo pipefail
      test "$(id -u)" != "0"
      if touch /syrus-confinement-root-write; then
        exit 1
      fi
      while [ "$#" -gt 0 ]; do
        timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$1" "$2"
        shift 2
      done
      if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'; then
        exit 1
      fi
      if timeout 3 bash -c 'exec 3<>/dev/tcp/169.254.169.254/80'; then
        exit 1
      fi
    BASH

    def self.capability_probes(env: ENV)
      [ {
        dimension: "runtime",
        token: RUNTIME_TOKEN,
        diagnostic_key: RUNTIME_TOKEN,
        command: probe_command(env),
        timeout: PROBE_TIMEOUT_SECONDS,
        diagnostics: {
          "confined_coworker_configuration" => configured?(env) ? "complete" : "missing",
          "confined_coworker_missing_settings" => missing_settings(env),
          "confined_coworker_verification" => [ "per_turn_container", "read_only_root", "non_root_user", "proxy_reachability", "default_deny_direct_egress" ]
        }
      } ]
    end

    def self.configured?(env)
      missing_settings(env).empty?
    end

    def self.missing_settings(env)
      missing = []
      missing << "docker_command" if Configuration.docker_command_path.blank?
      missing << "image" if Configuration.image.blank?
      missing << "docker_transport" unless Configuration.docker_transport_available?
      missing << "mcp_socket" if Configuration.mcp_socket_path.blank?
      missing << "mcp_socket_host_path" if Configuration.mcp_socket_path.present? && Configuration.host_path_for(Configuration.mcp_socket_path).blank?
      missing << "host_path_mappings" if Configuration.host_path_mappings.empty?
      missing << "dedicated_network" if Configuration.chat_agent_network.blank?
      missing << "controlled_dns" if Configuration.chat_agent_dns.blank?
      PROVIDERS.each do |provider|
        policy = EgressPolicy::Base.for(provider.downcase)
        missing << "#{provider.downcase}_proxy" unless env["SYRUS_CONTAINER_EXECUTION_#{provider}_PROXY"].present? && policy&.configured?
      end
      missing
    end

    def self.probe_command(env)
      return [ RbConfig.ruby, "-e", "exit 78" ] unless configured?(env)

      proxy_endpoints = PROVIDERS.map do |provider|
        uri = URI.parse(env.fetch("SYRUS_CONTAINER_EXECUTION_#{provider}_PROXY"))
        [ uri.hostname, uri.port ]
      end
      [
        Configuration.docker_command_path, "run", "--rm",
        "--network", Configuration.chat_agent_network,
        "--dns", Configuration.chat_agent_dns,
        "--read-only", "--user", Configuration.chat_agent_user,
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--security-opt", "seccomp=#{Configuration.seccomp_profile}",
        "--pids-limit", Configuration.chat_agent_pids_limit.to_s,
        "--memory", Configuration.chat_agent_memory,
        "--cpus", Configuration.chat_agent_cpus,
        "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=#{Configuration.chat_agent_tmpfs_size}",
        Configuration.image, "bash", "-c", PROBE_SCRIPT, "probe",
        *proxy_endpoints.flatten.map(&:to_s)
      ]
    end
  end
end
