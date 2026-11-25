module RuntimeImages
  # Namespace for the OCI-registry provider. Zeitwerk loads the children.
  module OciRegistry
    # Builds the provider from deployment environment, or nil when no registry
    # is configured.
    def self.provider_from_env(env = ENV)
      configuration = Configuration.from_env(env)
      configuration && Provider.new(configuration: configuration)
    end
  end
end
