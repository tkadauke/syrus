class PermissionLease < ApplicationRecord
  DURATION_KINDS = %w[ invocation chat_session job ].freeze

  belongs_to :owner_user, class_name: "User"
  belongs_to :subject_repository, class_name: "Repository", optional: true
  belongs_to :chat_session, optional: true
  belongs_to :job, optional: true
  belongs_to :source, polymorphic: true, optional: true
  belongs_to :issued_by_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true
  has_many :authorized_invocations, as: :authority, dependent: :nullify

  validates :subject_selector_type, inclusion: { in: PermissionRule::SUBJECT_SELECTOR_TYPES }
  validates :capability, :resource_type, presence: true
  validates :duration_kind, inclusion: { in: DURATION_KINDS }
  validates :used_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_uses, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :validate_json_shapes
  validate :validate_duration
  validate :validate_revocation_attribution
  validate :validate_use_limit
  validate :validate_subject_selector
  validate :validate_revoked_lease_is_immutable, on: :update

  before_validation :canonicalize_json

  scope :not_revoked, -> { where(revoked_at: nil) }
  scope :not_expired, ->(at = Time.current) { where(expires_at: nil).or(where(expires_at: at...)) }
  scope :with_uses_remaining, -> { where(max_uses: nil).or(where("used_count < max_uses")) }
  scope :for_invocation, ->(owner:, capability:, operation:) do
    not_revoked.not_expired.with_uses_remaining.where(owner_user: owner, capability: capability)
      .where(operation: [ nil, operation ])
  end

  def available?(context:, fingerprint:, effects:, arguments:, at: Time.current)
    revoked_at.nil? && (expires_at.nil? || expires_at > at) && uses_remaining? &&
      effects.map(&:to_s).all? { |effect| self.effects.include?(effect) } &&
      constraints_match?(arguments) && duration.available?(context:, fingerprint:)
  end

  def consume!
    raise ActiveRecord::RecordInvalid, self unless uses_remaining?

    increment!(:used_count)
  end

  def revoke!(actor:, at: Time.current)
    transaction do
      with_lock do
        return self if revoked_at?

        update!(revoked_at: at, revoked_by_user: actor)
      end
      AuthorizedInvocation.invalidate_unclaimed_for!(self)
    end
    self
  end

  def to_policy_rule
    Permissions::PolicyRule.new(
      id: "permission-lease-#{id}", layer: :lease, policy: :allow, source: "permission_lease",
      capability:, operation:, resource_scope:, selectors: subject_selectors,
      delegable: true, rationale: "Temporary delegated authority"
    )
  end

  private

  def duration
    PermissionLease::Duration.for(duration_kind, self)
  end

  def uses_remaining?
    max_uses.nil? || used_count < max_uses
  end

  def subject_selectors
    { subject_selector_type: }.tap do |selectors|
      selectors[:subject_selector_id] = subject_selector_id if subject_selector_id.present?
      selectors[:subject_repository_id] = subject_repository_id if subject_repository_id.present?
    end
  end

  def canonicalize_json
    self.resource_scope = canonical(resource_scope) if resource_scope.is_a?(Hash)
    self.constraints = canonical(constraints) if constraints.is_a?(Hash)
    self.effects = Array(effects).map(&:to_s).uniq.sort if effects.is_a?(Array)
  end

  def canonical(value)
    case value
    when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
    when Array then value.map { |item| canonical(item) }
    when Symbol then value.to_s
    else value
    end
  end

  def validate_duration
    return unless duration_kind.in?(DURATION_KINDS)

    duration.validate(self)
  end

  def validate_json_shapes
    %i[resource_scope constraints].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
    errors.add(:effects, "must be a JSON array") unless effects.is_a?(Array)
  end

  def validate_revocation_attribution
    return if revoked_at.present? == revoked_by_user_id.present?

    errors.add(:revoked_by_user, "must be present exactly when the lease is revoked")
  end

  def validate_use_limit
    errors.add(:used_count, "cannot exceed max uses") if max_uses && used_count > max_uses
  end

  def validate_subject_selector
    definition = PermissionRule::SUBJECT_SELECTORS[subject_selector_type]
    return unless definition

    errors.add(:subject_selector_id, "is required for this selector") if definition[:id] && subject_selector_id.blank?
    errors.add(:subject_selector_id, "must be blank for this selector") if !definition[:id] && subject_selector_id.present?
    errors.add(:subject_repository, "is required for this selector") if definition[:repository] && subject_repository_id.blank?
  end

  def validate_revoked_lease_is_immutable
    return if revoked_at_was.blank?
    return unless changes_to_save.except("updated_at", "lock_version").any?

    errors.add(:base, "Revoked permission leases cannot be changed")
  end

  def constraints_match?(arguments)
    constraints.all? do |key, expected|
      actual = if arguments.respond_to?(:key?) && arguments.key?(key)
        arguments[key]
      elsif arguments.respond_to?(:key?) && arguments.key?(key.to_sym)
        arguments[key.to_sym]
      end
      actual == expected
    end
  end
end
