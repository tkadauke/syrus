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
        errors.add(:base, "an invalidated override cannot be consumed")
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
    errors.add(:gate_kind, "is not registered") unless registry.registered?(gate_kind)
  end

  def failure_is_technically_overridable
    unless registry.registered?(gate_kind) && registry.fetch(gate_kind).overridable_failure?(gate_failure)
      errors.add(:base, "gate failure is not technically overridable")
    end
  end

  def set_fingerprint_digest
    self.fingerprint_digest = fingerprint.digest
  end

  def lineage_is_consistent
    errors.add(:workflow, "must belong to the override Job") if workflow && workflow.job_id != job_id
    errors.add(:step, "requires a Workflow") if step && !workflow
    errors.add(:step, "must belong to the override Workflow") if step && step.workflow_id != workflow_id
  end

  def version_binding_is_present
    errors.add(:base, "a plan or prompt version is required") if plan_version.blank? && prompt_version.blank?
  end

  def failure_matches_bound_evidence
    failure = gate_failure.to_h.symbolize_keys
    %i[gate_identity evidence_digest].each do |attribute|
      errors.add(attribute, "does not match the gate failure") unless failure[attribute].to_s == public_send(attribute).to_s
    end

    WorkflowOutcomeOverrides::Fingerprint::ATTRIBUTES.each do |attribute|
      next unless failure.key?(attribute)
      errors.add(attribute, "does not match the gate failure") unless failure[attribute].to_s == public_send(attribute).to_s
    end
  end

  def fingerprint_digest_is_exact
    return if fingerprint_digest.blank?

    errors.add(:fingerprint_digest, "does not match the bound evidence and revision") unless fingerprint_digest == fingerprint.digest
  end

  def valid_fingerprint?(expected)
    expected = WorkflowOutcomeOverrides::Fingerprint.new(**expected.symbolize_keys) if expected.respond_to?(:symbolize_keys)
    return true if expected.is_a?(WorkflowOutcomeOverrides::Fingerprint) && expected.digest == fingerprint_digest

    errors.add(:base, "override fingerprint does not match the current gate evidence and revision")
    false
  end

  def claims_are_immutable
    changed = changes_to_save.keys - MUTABLE_LIFECYCLE_ATTRIBUTES
    errors.add(:base, "override claims are immutable: #{changed.join(', ')}") if changed.any?
  end

  def lifecycle_is_monotonic
    if consumed_at_in_database.present? && consumed_at != consumed_at_in_database
      errors.add(:consumed_at, "is immutable once set")
    end
    if invalidation_cause_in_database.present? && invalidation_cause != invalidation_cause_in_database
      errors.add(:invalidation_cause, "is immutable once set")
    end
    if consumed_at.present? && invalidation_cause.present?
      errors.add(:base, "an override cannot be both consumed and invalidated")
    end
  end
end
