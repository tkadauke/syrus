# Cluster counters buffer increments in-process (Metrics::ClusterCounters);
# tests never auto-flush, so drop whatever an example buffered.
RSpec.configure do |config|
  config.after { Metrics::ClusterCounters.reset! }
end
