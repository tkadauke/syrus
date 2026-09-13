# Samples global queue gauges into the cache for /metrics to render.
#
# Runs on `control_plane` rather than `polling`: the whole point of these
# numbers is to reveal a polling backlog, so sampling them from behind that same
# backlog would make the metric disappear exactly when it matters most.
class SampleQueueMetricsJob < ApplicationJob
  def perform
    Metrics::QueueSampler.sample!
  end
end
