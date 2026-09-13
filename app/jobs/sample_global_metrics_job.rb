# Samples cluster-wide gauges into the cache for /metrics to render.
#
# Runs on `control_plane` rather than `polling`: the queue gauges exist to
# reveal a polling backlog, so sampling them from behind that same backlog would
# make the metric disappear exactly when it matters most.
#
# Each sampler degrades on its own -- one unreachable source costs its own
# gauges, not the whole tick.
class SampleGlobalMetricsJob < ApplicationJob
  SAMPLERS = [ Metrics::QueueSampler, Metrics::PluginSampler ].freeze

  def perform
    SAMPLERS.each do |sampler|
      sampler.sample!
    rescue StandardError => e
      Rails.logger.warn("[SampleGlobalMetricsJob] #{sampler} failed: #{e.class}: #{e.message}")
    end
  end
end
