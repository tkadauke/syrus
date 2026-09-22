module GitMirror
  # The container this plugin asks Plugin Runtime to run. See
  # PluginRuntime::Service for the contract.
  class RuntimeService
    def self.service_name = Configuration::SERVICE_NAME

    def self.service_spec
      {
        image: Configuration.image,
        internal_port: 8080,
        volumes: [ { name: "data", mount_path: "/data" } ],
        env: { "GIT_MIRROR_TOKEN" => Configuration.token },
        healthcheck: { path: "/healthz" }
      }
    end
  end
end
