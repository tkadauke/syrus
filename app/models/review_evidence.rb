class ReviewEvidence < ApplicationRecord
  STATES = %w[pending submitted failed stale].freeze
  REVIEW_KINDS = %w[adversarial security coworker].freeze

  belongs_to :run
  belongs_to :workflow
  belongs_to :step
  belongs_to :reviewer, polymorphic: true, optional: true

  validates :run_id, uniqueness: true
  validates :review_kind, inclusion: { in: REVIEW_KINDS }
  validates :state, inclusion: { in: STATES }
  validates :provider, :model, :reviewed_base_sha, :reviewed_head_sha,
            :canonical_diff_sha256, :prompt_version, :checklist_version,
            :tool_policy_version, presence: true
  validate :lineage_matches_run
  validate :immutable_provenance, on: :update
  validate :stale_state_is_monotonic, on: :update
  validate :envelopes_are_write_once, on: :update

  # The generic evidence row carries only opaque, JSON-safe envelopes for
  # plugin reviewer targets. `reviewer` (polymorphic) is the legacy,
  # read-only form kept for historical rows; new rows write `target` only.
  def review_target = target.presence&.deep_stringify_keys

  def record_context_manifest!(manifest)
    return context_manifest if context_manifest.present?

    update!(context_manifest: manifest.to_h.deep_stringify_keys)
    context_manifest
  end

  def record_persistence_receipt!(receipt)
    return persistence_receipt if persistence_receipt.present?

    update!(persistence_receipt: receipt.to_h.deep_stringify_keys)
    persistence_receipt
  end

  def mark_submitted!
    update!(state: "submitted", submitted_at: Time.current)
  end

  def mark_stale!(code:, details: {})
    return self if stale?

    update!(state: "stale", stale_at: Time.current,
            terminal_failure_code: code, terminal_failure_details: details)
  end

  def mark_failed!(code:, details: {})
    return self if stale?

    update!(state: "failed", failed_at: Time.current,
            terminal_failure_code: code, terminal_failure_details: details)
  end

  def stale? = state == "stale"

  private

  def lineage_matches_run
    return if run.blank?

    errors.add(:workflow, :review_evidence_run_lineage) unless workflow_id == run.workflow_id
    errors.add(:step, :review_evidence_run_lineage) unless step_id == run.step_id
  end

  def immutable_provenance
    immutable = %w[run_id workflow_id step_id review_kind provider model reviewer_type reviewer_id
                   reviewed_base_sha reviewed_head_sha canonical_diff_sha256 prompt_version
                   checklist_version tool_policy_version]
    changed = changes_to_save.keys & immutable
    errors.add(:base, :review_evidence_provenance_immutable, attributes: changed.join(", ")) if changed.any?
  end

  def envelopes_are_write_once
    %w[target context_manifest persistence_receipt].each do |attribute|
      next unless will_save_change_to_attribute?(attribute)
      next if attribute_in_database(attribute).blank?

      errors.add(:base, :review_evidence_provenance_immutable, attributes: attribute)
    end
  end

  def stale_state_is_monotonic
    errors.add(:state, :review_evidence_stale_monotonic) if state_in_database == "stale" && state != "stale"
  end
end
