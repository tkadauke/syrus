# Register the configured OCI registry as a Runtime Image Service provider.
# to_prepare because RuntimeImages::Providers is reloadable code.
Rails.application.config.to_prepare do
  provider = RuntimeImages::OciRegistry.provider_from_env
  RuntimeImages::Providers.register(provider) if provider
rescue RuntimeImages::Error => e
  Rails.logger.error("runtime image registry misconfigured: #{e.message}")
end
