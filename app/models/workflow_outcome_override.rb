class WorkflowOutcomeOverride < ApplicationRecord
  CHANNELS = %w[ui agent api console].freeze
  ORIGINAL_OUTCOME = "failed".freeze
  MUTABLE_LIFECYCLE_ATTRIBUTES = %w[consumed_at invalidation_cause updated_at].freeze

  attr_accessor :gate_failure

  belongs_to :job
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :actor, polymorphic: true

  validates :gate_kind, :gate_identity, :candidate_head_sha, :evidence_digest,
    :fingerprint_digest, :channel, :reason, presence: true
  validates :original_outcome, inclusion: { in: [ ORIGINAL_OUTCOME ] }
  validates :channel, inclusion: { in: CHANNELS }
  validates :permission_decision, presence: true
  validate :failure_is_technically_overridable, on: :create
  validate :registered_gate_kind
  validate :lineage_is_consistent
  validate :version_binding_is_present
  validate :failure_matches_bound_evidence, on: :create
  validate :fingerprint_digest_is_exact
  validate :claims_are_immutable, on: :update
  validate :lifecycle_is_monotonic, on: :update

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "WorkflowOutcomeOverride is append-only" }
  before_validation :set_fingerprint_digest, on: :create
  after_update_commit :record_consumption_telemetry, if: :consumed_now?

  def self.record!(gate_failure:, **attributes)
    create!(attributes.merge(gate_failure:, original_outcome: ORIGINAL_OUTCOME))
  end

  def effective_state = "failed, overridden"
  def fingerprint = WorkflowOutcomeOverrides::Fingerprint.from(self)
  def consumed? = consumed_at.present?
  def invalidated? = invalidation_cause.present?

  def consume!(expected_fingerprint, at: Time.current)
    with_lock do
      raise ActiveRecord::RecordInvalid, self unless valid_fingerprint?(expected_fingerprint)
      if invalidated?
        errors.add(:base, I18n.t("models.workflow_outcome_override.errors.invalidated_cannot_be_consumed"))
        raise ActiveRecord::RecordInvalid, self
      end
      return self if consumed?

      update!(consumed_at: at)
    end
    self
  end

  def invalidate!(cause)
    raise ArgumentError, "invalidation cause is required" if cause.blank?

    with_lock do
      return self if invalidation_cause == cause
      raise ActiveRecord::ReadOnlyRecord, "override invalidation is immutable" if invalidated? || consumed?

      update!(invalidation_cause: cause)
    end
    self
  end

  private

  def registry = WorkflowOutcomeOverrides::GateRegistry.default

  def registered_gate_kind
    errors.add(:gate_kind, I18n.t("models.workflow_outcome_override.errors.gate_kind_not_registered")) unless registry.registered?(gate_kind)
  end

  def failure_is_technically_overridable
    unless registry.registered?(gate_kind) && registry.fetch(gate_kind).overridable_failure?(gate_failure)
      errors.add(:base, I18n.t("models.workflow_outcome_override.errors.failure_not_overridable"))
    end
  end

  def set_fingerprint_digest
    self.fingerprint_digest = fingerprint.digest
  end

  def lineage_is_consistent
    errors.add(:workflow, I18n.t("models.workflow_outcome_override.errors.workflow_job_mismatch")) if workflow && workflow.job_id != job_id
    errors.add(:step, I18n.t("models.workflow_outcome_override.errors.step_requires_workflow")) if step && !workflow
    errors.add(:step, I18n.t("models.workflow_outcome_override.errors.step_workflow_mismatch")) if step && step.workflow_id != workflow_id
  end

  def version_binding_is_present
    errors.add(:base, I18n.t("models.workflow_outcome_override.errors.version_required")) if plan_version.blank? && prompt_version.blank?
  end

  def failure_matches_bound_evidence
    failure = gate_failure.to_h.symbolize_keys
    %i[gate_identity evidence_digest].each do |attribute|
      errors.add(attribute, I18n.t("models.workflow_outcome_override.errors.gate_failure_mismatch")) unless failure[attribute].to_s == public_send(attribute).to_s
    end

    WorkflowOutcomeOverrides::Fingerprint::ATTRIBUTES.each do |attribute|
      next unless failure.key?(attribute)
      errors.add(attribute, I18n.t("models.workflow_outcome_override.errors.gate_failure_mismatch")) unless failure[attribute].to_s == public_send(attribute).to_s
    end
  end

  def fingerprint_digest_is_exact
    return if fingerprint_digest.blank?

    errors.add(:fingerprint_digest, I18n.t("models.workflow_outcome_override.errors.fingerprint_digest_mismatch")) unless fingerprint_digest == fingerprint.digest
  end

  def valid_fingerprint?(expected)
    expected = WorkflowOutcomeOverrides::Fingerprint.new(**expected.symbolize_keys) if expected.respond_to?(:symbolize_keys)
    return true if expected.is_a?(WorkflowOutcomeOverrides::Fingerprint) && expected.digest == fingerprint_digest

    errors.add(:base, I18n.t("models.workflow_outcome_override.errors.current_fingerprint_mismatch"))
    false
  end

  def claims_are_immutable
    changed = changes_to_save.keys - MUTABLE_LIFECYCLE_ATTRIBUTES
    errors.add(:base, I18n.t("models.workflow_outcome_override.errors.claims_immutable", attributes: changed.join(", "))) if changed.any?
  end

  def lifecycle_is_monotonic
    if consumed_at_in_database.present? && consumed_at != consumed_at_in_database
      errors.add(:consumed_at, I18n.t("models.workflow_outcome_override.errors.consumed_at_immutable"))
    end
    if invalidation_cause_in_database.present? && invalidation_cause != invalidation_cause_in_database
      errors.add(:invalidation_cause, I18n.t("models.workflow_outcome_override.errors.invalidation_cause_immutable"))
    end
    if consumed_at.present? && invalidation_cause.present?
      errors.add(:base, I18n.t("models.workflow_outcome_override.errors.terminal_states_mutually_exclusive"))
    end
  end

  def consumed_now?
    consumed_at_before_last_save.blank? && consumed_at.present?
  end

  def record_consumption_telemetry
    WorkflowOutcomeOverrides::Telemetry.record_consumed(self)
  end
end
