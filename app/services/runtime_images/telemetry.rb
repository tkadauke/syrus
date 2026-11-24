module RuntimeImages
  # Counters for Runtime Image Service operations. Gauges describing current
  # state live in Metrics::RuntimeImageSampler so they are sampled once, not
  # per process. Tags are bounded: kind is the operation, outcome its result.
  module Telemetry
    def self.declare_metrics!
      Syrus::Metrics.declare do
        counter :runtime_image_operations_total, tags: %i[kind outcome], cluster: true,
                comment: "Runtime Image Service operations by kind (publish, revoke, retain, delete, gc, " \
                         "reconcile, auth) and outcome (ok, failed, skipped, repaired, detected)"
      end
    end
    declare_metrics!

    def self.operation(kind, outcome)
      Syrus::Metrics.counter(:syrus_runtime_image_operations_total).increment(tags: { kind: kind.to_s, outcome: outcome.to_s })
    rescue StandardError => e
      Rails.logger.warn("[RuntimeImages::Telemetry] #{e.class}: #{e.message}")
    end
  end
end
