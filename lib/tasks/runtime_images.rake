namespace :runtime_images do
  desc "Check connectivity and credential roles of the configured OCI registry"
  task diagnose: :environment do
    provider = RuntimeImages::OciRegistry.provider_from_env
    abort "No runtime image registry configured (set SYRUS_RUNTIME_IMAGE_REGISTRY_URL)" unless provider
    diagnostics = RuntimeImages::OciRegistry::Diagnostics.new(provider)
    checks = diagnostics.run
    checks.each { |c| puts format("%-4s %-22s %s", c.status.to_s.upcase, c.name, c.detail) }
    exit 1 unless diagnostics.ok?(checks)
  end
end
