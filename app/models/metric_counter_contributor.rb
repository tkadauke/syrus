# One process participating in cluster-counter capture. The applied sequence is
# the durable idempotency watermark; freshness/error fields make partial
# capture visible to the sampler and dashboard.
class MetricCounterContributor < ApplicationRecord
end
