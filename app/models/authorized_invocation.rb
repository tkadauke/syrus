class AuthorizedInvocation < ApplicationRecord
  STATES = %w[ issued claimed succeeded failed invalidated non_resumable ].freeze
  RESULT_STATUSES = %w[ succeeded failed ].freeze
  LIFECYCLE_ATTRIBUTES = %w[
    state claim_key claimed_by_type claimed_by_id claimed_at executed_at result_status
    result_type result_id invalidated_at invalidation_reason
  ].freeze
  TRANSITION_ATTRIBUTES = {
    %w[issued claimed] => %w[state claim_key claimed_by_type claimed_by_id claimed_at],
    %w[issued invalidated] => %w[state invalidated_at invalidation_reason],
    %w[issued non_resumable] => %w[state invalidated_at invalidation_reason],
    %w[claimed succeeded] => %w[state executed_at result_status result_type result_id],
    %w[claimed failed] => %w[state executed_at result_status result_type result_id]
  }.freeze

  ClaimResult = Data.define(:status, :invocation) do
    def claimed? = status == :claimed
    def already_claimed? = status == :already_claimed
  end

  belongs_to :pending_action_item
  belongs_to :authority, polymorphic: true, optional: true
  belongs_to :claimed_by, polymorphic: true, optional: true
  belongs_to :result, polymorphic: true, optional: true

  enum :state, STATES.index_with(&:itself), validate: true

  attribute :execution_authority, :json, default: -> { {} }
  attribute :audit_payload, :json, default: -> { {} }

  validates :invocation_fingerprint, :tool_name, presence: true
  validates :pending_action_item_id, uniqueness: true
  validates :claim_key, uniqueness: true, allow_nil: true
  validates :result_status, inclusion: { in: RESULT_STATUSES }, allow_nil: true
  validate :operation_item_matches_fingerprint
  validate :validate_json_shapes
  validate :validate_claim_fields
  validate :immutable_authorization, on: :update
  validate :forward_only_lifecycle, on: :update

  before_validation :canonicalize_json

  scope :unclaimed, -> { where(state: "issued") }

  def self.issue!(pending_action_item:, authority: nil, tool_name:, execution_authority: {}, audit_payload: {})
    attributes = {
      pending_action_item:, authority:, tool_name:,
      invocation_fingerprint: pending_action_item.invocation_fingerprint,
      execution_authority:, audit_payload:
    }
    return issue_under_lock!(attributes) unless authority

    authority.with_lock do
      existing = find_by(pending_action_item:)
      return existing if existing

      unless authority.revoked_at.nil?
        invocation = new(attributes)
        invocation.errors.add(:authority, "has been revoked")
        raise ActiveRecord::RecordInvalid, invocation
      end

      issue_under_lock!(attributes)
    end
  end

  def self.issue_under_lock!(attributes)
    pending_action_item = attributes.fetch(:pending_action_item)
    existing = find_by(pending_action_item:)
    return existing if existing

    create!(attributes)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by(pending_action_item:) || raise
  end
  private_class_method :issue_under_lock!

  # Both callbacks run under the row lock and must be side-effect-free. Dispatch
  # belongs exclusively to the caller that receives a newly claimed result.
  def claim!(fingerprint:, claimant:, claim_key:, revalidate:, origin_resumable:)
    raise ArgumentError, "claim_key is required" if claim_key.blank?
    raise ArgumentError, "revalidate must be callable" unless revalidate.respond_to?(:call)
    raise ArgumentError, "origin_resumable must be callable" unless origin_resumable.respond_to?(:call)

    claim = -> { claim_under_lock!(fingerprint:, claimant:, claim_key:, revalidate:, origin_resumable:) }
    return claim.call unless authority

    authority.with_lock { claim.call }
  rescue ActiveRecord::RecordNotUnique
    reload
    ClaimResult.new(status: self.claim_key == claim_key ? :already_claimed : :unavailable, invocation: self)
  end

  def claim_under_lock!(fingerprint:, claimant:, claim_key:, revalidate:, origin_resumable:)
    with_lock do
      if claimed? || succeeded? || failed?
        status = self.claim_key == claim_key ? :already_claimed : :unavailable
        return ClaimResult.new(status:, invocation: self)
      end
      return ClaimResult.new(status: :unavailable, invocation: self) unless issued?

      unless fingerprint_matches?(fingerprint)
        invalidate_locked!("invocation_fingerprint_mismatch")
        return ClaimResult.new(status: :fingerprint_mismatch, invocation: self)
      end
      unless origin_resumable.call(self)
        update!(state: "non_resumable", invalidated_at: Time.current,
          invalidation_reason: "origin_no_longer_resumable")
        return ClaimResult.new(status: :non_resumable, invocation: self)
      end

      validation = revalidate.call(self)
      unless validation == true
        reason = validation.respond_to?(:reason) ? validation.reason : validation
        invalidate_locked!(reason.presence || "execution_revalidation_failed")
        return ClaimResult.new(status: :revalidation_failed, invocation: self)
      end

      update!(state: "claimed", claim_key:, claimed_by: claimant, claimed_at: Time.current)
      ClaimResult.new(status: :claimed, invocation: self)
    end
  end
  private :claim_under_lock!

  def complete!(claim_key:, status:, result: nil, at: Time.current)
    status = status.to_s
    raise ArgumentError, "status must be succeeded or failed" unless status.in?(RESULT_STATUSES)

    with_lock do
      if succeeded? || failed?
        return self if self.claim_key == claim_key && result_status == status && self.result == result

        raise ActiveRecord::RecordInvalid, self
      end
      raise ActiveRecord::RecordInvalid, self unless claimed? && self.claim_key == claim_key

      update!(state: status, result_status: status, result:, executed_at: at)
    end
    self
  end

  def invalidate!(reason)
    with_lock do
      return false unless issued?

      invalidate_locked!(reason)
    end
    true
  end

  def self.invalidate_unclaimed_for!(authority, reason: "authority_revoked")
    where(authority:).unclaimed.find_each { |invocation| invocation.invalidate!(reason) }
  end

  private

  def fingerprint_matches?(candidate)
    candidate.present? && candidate.bytesize == invocation_fingerprint.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(invocation_fingerprint, candidate)
  end

  def invalidate_locked!(reason)
    update!(state: "invalidated", invalidated_at: Time.current, invalidation_reason: reason.to_s)
  end

  def operation_item_matches_fingerprint
    return unless pending_action_item

    errors.add(:pending_action_item, "must be an approved operation") unless pending_action_item.kind == "operation" && pending_action_item.approved?
    if pending_action_item.invocation_fingerprint != invocation_fingerprint
      errors.add(:invocation_fingerprint, "must exactly match the approved item")
    end
  end

  def validate_json_shapes
    errors.add(:execution_authority, "must be a JSON object") unless execution_authority.is_a?(Hash)
    errors.add(:audit_payload, "must be a JSON object") unless audit_payload.is_a?(Hash)
  end

  def validate_claim_fields
    fields_present = claim_key.present? && claimed_by.present? && claimed_at.present?
    claimed_or_completed = claimed? || state.in?(RESULT_STATUSES)
    errors.add(:base, "claimed invocations require complete claim attribution") if claimed_or_completed && !fields_present
    if state.in?(RESULT_STATUSES)
      errors.add(:executed_at, "is required for a result") if executed_at.blank?
      errors.add(:result_status, "must match the terminal state") unless result_status == state
    end
    if invalidated? || non_resumable?
      errors.add(:invalidated_at, "is required for invalidation") if invalidated_at.blank?
      errors.add(:invalidation_reason, "is required for invalidation") if invalidation_reason.blank?
    end
  end

  def immutable_authorization
    immutable = %w[pending_action_item_id authority_type authority_id invocation_fingerprint tool_name execution_authority audit_payload created_at]
    errors.add(:base, "Authorized invocation claims are immutable") if changes_to_save.keys.intersect?(immutable)
  end

  def forward_only_lifecycle
    changed = changes_to_save.keys.intersection(LIFECYCLE_ATTRIBUTES)
    return if changed.empty?

    from = state_in_database
    allowed = TRANSITION_ATTRIBUTES[[ from, state ]]
    if allowed.nil? || (changed - allowed).any?
      errors.add(:base, "Authorized invocation lifecycle is immutable outside its permitted transition")
    end
  end

  def canonicalize_json
    self.execution_authority = canonical(execution_authority) if execution_authority.is_a?(Hash)
    self.audit_payload = canonical(audit_payload) if audit_payload.is_a?(Hash)
  end

  def canonical(value)
    case value
    when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
    when Array then value.map { |item| canonical(item) }
    when Symbol then value.to_s
    else value
    end
  end
end
