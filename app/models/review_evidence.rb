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

    errors.add(:workflow, "must match the Run lineage") unless workflow_id == run.workflow_id
    errors.add(:step, "must match the Run lineage") unless step_id == run.step_id
  end

  def immutable_provenance
    immutable = %w[run_id workflow_id step_id review_kind provider model reviewer_type reviewer_id reviewer_target_snapshot
                   reviewed_base_sha reviewed_head_sha canonical_diff_sha256 prompt_version
                   checklist_version tool_policy_version]
    changed = changes_to_save.keys & immutable
    errors.add(:base, "review evidence provenance is immutable: #{changed.join(', ')}") if changed.any?
  end

  def stale_state_is_monotonic
    errors.add(:state, "cannot leave stale") if state_in_database == "stale" && state != "stale"
  end
end
