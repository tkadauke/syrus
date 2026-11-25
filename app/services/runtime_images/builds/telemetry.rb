module RuntimeImages
  module Builds
    # Counters for the build plane. Tags are bounded: +outcome+ is an attempt
    # outcome and +reason+ (the error code) is folded into KNOWN_CODES so an unexpected error
    # string can never create a new time series.
    module Telemetry
      KNOWN_CODES = %w[
        none build_failed build_timeout build_stopped builder_not_isolated builder_unavailable infrastructure_error
        lease_expired attempt_deadline_exceeded orphaned_request network_denied quota_exhausted registry_unavailable
        source_mismatch source_unattested verification_failed output_too_large output_invalid no_output
        source_invalid unexpected_error
      ].freeze
      RECOVERIES = %w[lease_expired attempt_deadline_exceeded orphaned_request duplicate_delivery duplicate_submit].freeze

      def self.declare_metrics!
        Syrus::Metrics.declare do
          counter :runtime_image_build_attempts_total, tags: %i[outcome reason], cluster: true,
                  comment: "Runtime image build attempts by terminal outcome (succeeded, failed, retried, canceled) and error code"
          counter :runtime_image_build_recoveries_total, tags: %i[reason], cluster: true,
                  comment: "Runtime image build recoveries by reason (lease_expired, attempt_deadline_exceeded, orphaned_request, " \
                           "duplicate_delivery, duplicate_submit)"
        end
      end
      declare_metrics!

      def self.attempt(outcome, code = nil)
        code = code.to_s.presence
        code = "other" unless code.nil? || KNOWN_CODES.include?(code)
        Syrus::Metrics.counter(:syrus_runtime_image_build_attempts_total).increment(tags: { outcome: outcome.to_s, reason: code || "none" })
      rescue StandardError => e
        Rails.logger.warn("[RuntimeImages::Builds::Telemetry] #{e.class}: #{e.message}")
      end

      def self.recovery(reason)
        reason = "other" unless RECOVERIES.include?(reason.to_s)
        Syrus::Metrics.counter(:syrus_runtime_image_build_recoveries_total).increment(tags: { reason: reason.to_s })
      rescue StandardError => e
        Rails.logger.warn("[RuntimeImages::Builds::Telemetry] #{e.class}: #{e.message}")
      end
    end
  end
end
