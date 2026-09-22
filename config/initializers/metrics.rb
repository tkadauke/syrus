# Core metrics are declared in the class body of whatever owns them, so that a
# metric and its instrumentation cannot drift apart. That only works if those
# classes are actually loaded: in production eager loading handles it, but under
# lazy loading in development and test a metric nobody has referenced yet is a
# metric that does not exist -- and the catalog would silently come out empty.
#
# So this is the list of core metric owners. It is the one place that has to be
# updated when a new subsystem starts declaring metrics, and it is deliberately
# a list of *owners* rather than of metrics: the declarations stay next to the
# code they measure.
#
# Plugin metrics are not here. They register through the plugin manifest's
# `metrics` block under while_enabled semantics, so a disabled plugin declares
# nothing (see Syrus::PluginApi::Definition#metrics).
Rails.application.config.to_prepare do
  [
    "SkipIfPending",
    "Metrics::QueueSampler",
    "Metrics::PluginSampler",
    "Metrics::ProductUsage",
    "Metrics::LandingSampler",
    "Metrics::WorkerSampler",
    "Metrics::FleetSampler",
    "Metrics::ResilienceSampler",
    "Metrics::MaintenanceSampler",
    "Metrics::AttentionSampler",
    "WorkflowAdmissionBudget",
    "RepositoryContent"
  ].each do |owner|
    owner.constantize
  rescue NameError => e
    Rails.logger&.warn("[Syrus::Metrics] could not load metric owner #{owner}: #{e.message}")
  end

  # Publish a zero for every known feature, so an unused one reads as 0 rather
  # than as a missing series -- which is the whole point of collecting these.
  begin
    Metrics::ProductUsage.preset_all!
  rescue StandardError => e
    Rails.logger&.warn("[Syrus::Metrics] could not preset product usage counters: #{e.message}")
  end
end
