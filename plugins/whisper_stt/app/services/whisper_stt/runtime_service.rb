module WhisperStt
  # The container this plugin asks Plugin Runtime to run. See
  # PluginRuntime::Service for the duck-type contract.
  class RuntimeService
    def self.service_name = Configuration::SERVICE_NAME

    def self.service_spec
      {
        image: Configuration.image,
        internal_port: 8080,
        env: {},
        healthcheck: { path: Configuration::HEALTH_PATH },
        memory_limit_bytes: Configuration.memory_limit_bytes
      }
    end
  end
end
