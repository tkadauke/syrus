class PermissionRule < ApplicationRecord
  POLICIES = %w[ deny ask allow ].freeze
  POLICY_LAYERS = %w[ instance team repository role agent ].freeze
  SUBJECT_SELECTORS = {
    "agent" => { id: true, repository: false, role_snapshot: false, dynamic: false },
    "interactive_chat" => { id: false, repository: false, role_snapshot: false, dynamic: false },
    "coding_chat" => { id: false, repository: false, role_snapshot: false, dynamic: false },
    "local_chat" => { id: false, repository: false, role_snapshot: false, dynamic: false },
    "workflow_role" => { id: true, repository: false, role_snapshot: false, dynamic: false },
    "repository_role" => { id: true, repository: true, role_snapshot: false, dynamic: false },
    "eligible_roles" => { id: false, repository: false, role_snapshot: true, dynamic: true }
  }.freeze
  SUBJECT_SELECTOR_TYPES = SUBJECT_SELECTORS.keys.freeze

  AUDITED_ATTRIBUTES = %w[
    owner_user_id subject_selector_type subject_selector_id subject_role_keys subject_repository_id
    capability operation resource_type resource_scope policy constraints policy_layer
    source provenance dynamic_future_roles delegable rationale created_by_user_id
    updated_by_user_id revoked_at revoked_by_user_id created_at updated_at
  ].freeze

  belongs_to :owner_user, class_name: "User"
  belongs_to :subject_repository, class_name: "Repository", optional: true
  belongs_to :created_by_user, class_name: "User"
  belongs_to :updated_by_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true

  has_many :audit_events, -> { order(:sequence) }, class_name: "PermissionRuleAuditEvent",
    dependent: :restrict_with_exception, inverse_of: :permission_rule
  has_many :authorized_invocations, as: :authority, dependent: :nullify

  validates :subject_selector_type, inclusion: { in: SUBJECT_SELECTOR_TYPES }
  validates :capability, :resource_type, :source, presence: true
  validates :policy, inclusion: { in: POLICIES }
  validates :policy_layer, inclusion: { in: POLICY_LAYERS }
  validate :validate_json_objects
  validate :validate_subject_selector
  validate :validate_dynamic_role_semantics
  validate :validate_revocation_attribution
  validate :validate_revoked_rule_is_immutable, on: :update

  scope :active, -> { where(revoked_at: nil) }
  scope :for_owner, ->(user) { where(owner_user: user) }
  scope :for_capability, ->(capability, operation = nil) do
    relation = where(capability: capability)
    operation.nil? ? relation : relation.where(operation: [ nil, operation ])
  end

  before_validation :canonicalize_json_objects
  before_destroy -> { raise ActiveRecord::ReadOnlyRecord, "PermissionRule must be revoked, not destroyed" }, prepend: true
  after_create :append_creation_event!
  after_update :append_change_event!

  def revoke!(actor:, at: Time.current)
    transaction do
      with_lock do
        return self if revoked_at?

        update!(revoked_at: at, revoked_by_user: actor, updated_by_user: actor)
      end
      AuthorizedInvocation.invalidate_unclaimed_for!(self)
    end
    self
  end

  def revise!(actor:, **attributes)
    raise ActiveRecord::ReadOnlyRecord, "Revoked permission rules cannot be changed" if revoked_at?

    update!(attributes.merge(updated_by_user: actor))
  end

  def to_policy_rule
    Permissions::PolicyRule.new(
      id: "permission-rule-#{id}", layer: policy_layer, policy:, source: "permission_rule",
      capability:, operation:, resource_scope:, selectors: subject_selectors,
      delegable:, rationale:
    )
  end

  private

  def subject_selectors
    { subject_selector_type: }.tap do |selectors|
      selectors[:subject_selector_id] = subject_selector_id if subject_selector_id.present?
      selectors[:subject_repository_id] = subject_repository_id if subject_repository_id.present?
    end
  end

  def canonicalize_json_objects
    self.resource_scope = canonicalize_json(resource_scope) if resource_scope.is_a?(Hash)
    self.constraints = canonicalize_json(constraints) if constraints.is_a?(Hash)
    self.provenance = canonicalize_json(provenance) if provenance.is_a?(Hash)
    self.subject_role_keys = Array(subject_role_keys).map(&:to_s).uniq.sort if subject_role_keys.is_a?(Array)
  end

  def canonicalize_json(value)
    case value
    when Hash
      value.to_h { |key, item| [ key.to_s, canonicalize_json(item) ] }.sort.to_h
    when Array
      value.map { |item| canonicalize_json(item) }
    when Symbol
      value.to_s
    else
      value
    end
  end

  def validate_json_objects
    %i[ resource_scope constraints provenance ].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
    errors.add(:subject_role_keys, "must be a JSON array") unless subject_role_keys.is_a?(Array)
  end

  def validate_subject_selector
    definition = SUBJECT_SELECTORS[subject_selector_type]
    return unless definition

    errors.add(:subject_selector_id, "is required for this selector") if definition[:id] && subject_selector_id.blank?
    errors.add(:subject_selector_id, "must be blank for this selector") if !definition[:id] && subject_selector_id.present?
    errors.add(:subject_repository, "is required for this selector") if definition[:repository] && subject_repository_id.blank?
    if definition[:role_snapshot] && !dynamic_future_roles && subject_role_keys.blank?
      errors.add(:subject_role_keys, "must capture the currently eligible roles")
    elsif !definition[:role_snapshot] && subject_role_keys.present?
      errors.add(:subject_role_keys, "must be blank for this selector")
    end
  end

  def validate_dynamic_role_semantics
    return unless dynamic_future_roles
    return if SUBJECT_SELECTORS.dig(subject_selector_type, :dynamic)

    errors.add(:dynamic_future_roles, "is only valid for the unscoped eligible_roles selector")
  end

  def validate_revocation_attribution
    return if revoked_at.present? == revoked_by_user_id.present?

    errors.add(:revoked_by_user, "must be present exactly when the rule is revoked")
  end

  def validate_revoked_rule_is_immutable
    return if revoked_at_was.blank?
    return unless changes_to_save.except("updated_at", "lock_version").any?

    errors.add(:base, "Revoked permission rules cannot be changed")
  end

  def append_creation_event!
    append_audit_event!("created", saved_changes.keys, actor: created_by_user)
  end

  def append_change_event!
    event_type = saved_change_to_revoked_at? && revoked_at? ? "revoked" : "updated"
    append_audit_event!(event_type, saved_changes.keys, actor: updated_by_user)
  end

  def append_audit_event!(event_type, changed_fields, actor:)
    audit_events.create!(
      sequence: audit_events.maximum(:sequence).to_i + 1,
      event_type: event_type,
      actor_user: actor,
      snapshot: attributes.slice(*AUDITED_ATTRIBUTES),
      changed_fields: changed_fields.map(&:to_s).sort,
      created_at: Time.current
    )
  end
end
