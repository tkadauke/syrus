# One cluster counter series' cumulative total across every process. Written
# only by Metrics::ClusterCounters' atomic upserts; read by its sampler.
class MetricCounterTotal < ApplicationRecord
end
