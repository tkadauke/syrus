# One episode of an invariant violation, as recorded by the invariant monitor
# (InvariantMonitorJob via Invariants::Recorder). Open while the violation
# keeps being detected; resolved the first evaluation it no longer appears.
# The live evaluation is Invariants.evaluate -- these rows add history: when a
# violation was first seen and how long it has persisted.
class InvariantViolation < ApplicationRecord
  validates :invariant_key, :fingerprint, :severity, :subject_type, :first_detected_at, :last_detected_at, presence: true
  validates :severity, inclusion: { in: Invariants::SEVERITIES }

  scope :open, -> { where(resolved_at: nil) }
  scope :resolved, -> { where.not(resolved_at: nil) }

  before_validation :sync_open_fingerprint

  def open? = resolved_at.nil?

  def message
    I18n.t("services.invariants.#{invariant_key}.violation", **message_params.to_h.symbolize_keys)
  end

  def as_json(*)
    {
      id: id,
      invariant: invariant_key,
      fingerprint: fingerprint,
      severity: severity,
      subject_type: subject_type,
      subject_id: subject_id,
      message: message,
      since: violating_since&.iso8601,
      first_detected_at: first_detected_at.iso8601,
      last_detected_at: last_detected_at.iso8601,
      resolved_at: resolved_at&.iso8601,
      detection_count: detection_count,
      affected_ids: affected_ids.to_h,
      details: details.to_h
    }
  end

  private

  def sync_open_fingerprint
    self.open_fingerprint = resolved_at.present? ? nil : fingerprint
  end
end
