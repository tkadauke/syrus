module RuntimeImages
  # Records a RuntimeImageAuditEvent and the matching operation counter.
  # Auditing is observational: a failure to record never changes the outcome
  # of the operation being audited.
  module Audit
    def self.record(event_type, outcome:, image: nil, namespace: nil, digest: nil, actor: "system", details: {})
      Telemetry.operation(event_type.to_s.split(".").first, outcome)
      RuntimeImageAuditEvent.create!(
        event_type: event_type.to_s, outcome: outcome.to_s, actor: actor,
        runtime_image_id: image&.id, runtime_image_namespace_id: namespace&.id || image&.runtime_image_namespace_id,
        digest: digest || image&.digest, details: sanitize(details)
      )
    rescue StandardError => e
      Rails.logger.warn("[RuntimeImages::Audit] could not record #{event_type}: #{e.class}: #{e.message}")
      nil
    end

    # Details are operator-facing; keep them small, flat, and secret-free.
    def self.sanitize(details)
      Hash(details).transform_keys(&:to_s).transform_values do |value|
        value.is_a?(String) ? value.truncate(500) : value
      end
    end
  end
end
