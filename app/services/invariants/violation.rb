require "digest"

module Invariants
  # One broken invariant about one subject.
  #
  # `fingerprint` identifies "the same violation" across evaluations: the
  # monitor keeps one open record per ongoing violation and resolves it once
  # the fingerprint stops appearing. `discriminator` separates distinct
  # violations about the same subject (two leaked locks on one WorkUnit, two
  # storming steps on one Job). `message_params` interpolate the translated
  # one-line message; `details` carry the structured evidence to act on.
  # `since` is when the violating condition started, when the invariant can
  # tell.
  Violation = Data.define(:invariant, :severity, :subject_type, :subject_id, :discriminator, :message_params, :details, :affected_ids, :since) do
    def initialize(invariant:, severity:, subject_type:, subject_id:, message_params:, details:, discriminator: nil, affected_ids: {}, since: nil)
      raise ArgumentError, "unknown severity #{severity.inspect}" unless SEVERITIES.include?(severity.to_s)

      super(
        invariant: invariant.to_s,
        severity: severity.to_s,
        subject_type: subject_type.to_s,
        subject_id: subject_id,
        discriminator: discriminator&.to_s,
        message_params: message_params.to_h.deep_stringify_keys,
        details: details.to_h.deep_stringify_keys,
        affected_ids: affected_ids.to_h.transform_keys(&:to_s).transform_values { |ids| Array(ids).compact.uniq.sort },
        since: since
      )
    end

    # Bounded to fit the recorded column: a long discriminator (a lock key)
    # keeps a readable prefix and a digest of the whole.
    def fingerprint
      raw = [ invariant, subject_type, subject_id, discriminator ].compact.join(":")
      return raw if raw.length <= FINGERPRINT_LIMIT

      "#{raw.first(FINGERPRINT_LIMIT - 17)}:#{Digest::SHA256.hexdigest(raw).first(16)}"
    end

    def message
      I18n.t("services.invariants.#{invariant}.violation", **message_params.symbolize_keys)
    end

    def as_json(*)
      {
        invariant: invariant,
        fingerprint: fingerprint,
        severity: severity,
        subject_type: subject_type,
        subject_id: subject_id,
        message: message,
        since: since&.iso8601,
        affected_ids: affected_ids,
        details: details
      }
    end
  end
end
