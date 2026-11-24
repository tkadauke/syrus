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

  desc "Print Runtime Image Service health checks, retained images, and failed cleanup"
  task status: :environment do
    health = RuntimeImages::Health.new
    health.checks.each { |c| puts format("%-4s %-24s %s", c.status.to_s.upcase, c.name, c.detail) }
    health.cleanup_failures.each { |f| puts "cleanup failed: #{f[:digest]} attempts=#{f[:attempts]} #{f[:last_error]}" }
    exit 1 unless health.ok?
  end

  desc "Reconcile image records with the registry (REPAIR=0 to only report, DELETE_ORPHANS=1 to remove unrecorded digests)"
  task reconcile: :environment do
    reconciler = RuntimeImages::Reconciler.new(repair: ENV["REPAIR"] != "0", delete_orphans: ENV["DELETE_ORPHANS"] == "1")
    findings = reconciler.call
    findings.each { |f| puts format("%-22s %-24s %-12s %s %s", f.kind, f.namespace, f.action, f.digest, f.detail) }
    puts "#{findings.size} finding(s)"
    exit 1 if findings.any? { |f| f.action == :failed }
  end
end
