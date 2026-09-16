# Samples cluster-wide gauges into the cache for /metrics to render, and lets
# Metrics::LandingSampler instrument its cursor-based counters/histograms on
# the same tick.
#
# Runs on `control_plane` rather than `polling`: the queue gauges exist to
# reveal a polling backlog, so sampling them from behind that same backlog would
# make the metric disappear exactly when it matters most.
#
# Each sampler degrades on its own -- one unreachable source costs its own
# gauges, not the whole tick.
class SampleGlobalMetricsJob < ApplicationJob
  # Metrics::LandingSampler advances a cursor across ticks; an overlapping
  # second tick reading the same "already instrumented through" boundary
  # before the first writes it back would double-count. One instance at a
  # time, same guard ReapStaleRunsJob uses for the same every-minute
  # control_plane shape.
  limits_concurrency to: 1, key: "sample_global_metrics", duration: 5.minutes, on_conflict: :discard

  SAMPLERS = [
    Metrics::QueueSampler,
    Metrics::PluginSampler,
    Metrics::LandingSampler,
    Metrics::WorkerSampler,
    Metrics::FleetSampler,
    Metrics::ResilienceSampler,
    Metrics::MaintenanceSampler
  ].freeze

  def perform
    SAMPLERS.each do |sampler|
      sampler.sample!
    rescue StandardError => e
      Rails.logger.warn("[SampleGlobalMetricsJob] #{sampler} failed: #{e.class}: #{e.message}")
    end
  end
end
