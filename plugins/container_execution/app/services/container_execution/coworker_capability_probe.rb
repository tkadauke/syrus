module ContainerExecution
  class CoworkerCapabilityProbe
    include Syrus::Plugin::WorkerCapabilityProbe

    RUNTIME_TOKEN = "confined_coworker".freeze

    def self.capability_probes(env: ENV)
      return [] unless configured?(env)

      [ {
        dimension: "runtime",
        token: RUNTIME_TOKEN,
        diagnostic_key: RUNTIME_TOKEN,
        command: [ Configuration.docker_command_path, "version", "--format", "{{.Server.Version}}" ]
      } ]
    end

    def self.configured?(env)
      Configuration.docker_command_path.present? &&
        Configuration.image.present? &&
        Configuration.docker_transport_available? &&
        Configuration.mcp_socket_path.present? &&
        Configuration.host_path_for(Configuration.mcp_socket_path).present? &&
        Configuration.host_path_mappings.any? &&
        Configuration.coworker_network.present? &&
        Configuration.coworker_dns.present? &&
        %w[CODEX CLAUDE MUSE AGY].all? { |provider| env["SYRUS_CONTAINER_EXECUTION_#{provider}_PROXY"].present? }
    end
  end
end
