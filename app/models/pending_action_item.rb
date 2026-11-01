class PendingActionItem < ApplicationRecord
  KINDS = %w[ capability_possession operation ].freeze
  STATES = %w[ pending approved denied cancelled non_actionable ].freeze
  DURATIONS = %w[ invocation chat_session job permanent ].freeze

  belongs_to :chat_pending_action, inverse_of: :authorization_items
  belongs_to :decision_principal, polymorphic: true, optional: true
  belongs_to :resulting_authority, polymorphic: true, optional: true
  has_many :prerequisite_links,
    class_name: "PendingActionItemPrerequisite",
    dependent: :destroy,
    inverse_of: :pending_action_item
  has_many :prerequisites, through: :prerequisite_links
  has_many :dependent_links,
    class_name: "PendingActionItemPrerequisite",
    foreign_key: :prerequisite_id,
    dependent: :destroy,
    inverse_of: :prerequisite
  has_many :dependents, through: :dependent_links, source: :pending_action_item
  has_many :transitions, class_name: "PendingActionTransition", dependent: :delete_all

  enum :state, STATES.index_with(&:itself), validate: true

  attribute :resource_scope, :json, default: -> { {} }
  attribute :normalized_arguments, :json, default: -> { {} }
  attribute :effects, :json, default: -> { [] }
  attribute :policy_chain, :json, default: -> { [] }
  attribute :decisive_rule, :json, default: -> { {} }
  attribute :requested_durations, :json, default: -> { [] }

  validates :kind, inclusion: { in: KINDS }
  validates :capability, :resource_type, presence: true
  validates :capability_version, numericality: { only_integer: true, greater_than: 0 }
  validates :operation_version, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :selected_duration, inclusion: { in: DURATIONS }, allow_nil: true
  validate :validate_json_shapes
  validate :validate_decision
  validate :validate_operation_item
  validate :validate_prerequisites_belong_to_request

  before_validation :canonicalize_json
  after_create :record_creation_transition!
  after_update :record_state_transition!, if: :saved_change_to_state?

  def prerequisites_approved?
    prerequisites.where.not(state: "approved").none?
  end

  def actionable?
    pending? && non_actionable_at.nil?
  end

  def decide!(decision, principal:, duration: nil, reason: nil, resulting_authority: nil)
    decision = decision.to_s
    raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

    with_lock do
      return false unless actionable?

      update!(
        state: decision,
        decision_principal: principal,
        selected_duration: duration,
        decision_reason: reason,
        resulting_authority: resulting_authority,
        decided_at: Time.current
      )
    end
    true
  end

  def mark_non_actionable!(reason)
    with_lock do
      return false unless pending?

      update!(state: "non_actionable", non_actionable_at: Time.current, non_actionable_reason: reason)
    end
    true
  end

  private

  def canonicalize_json
    self.resource_scope = canonical(resource_scope) if resource_scope.is_a?(Hash)
    self.normalized_arguments = canonical(normalized_arguments) if normalized_arguments.is_a?(Hash)
    self.effects = Array(effects).map(&:to_s).uniq.sort if effects.is_a?(Array)
    self.requested_durations = Array(requested_durations).map(&:to_s).uniq if requested_durations.is_a?(Array)
  end

  def canonical(value)
    case value
    when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
    when Array then value.map { |item| canonical(item) }
    when Symbol then value.to_s
    else value
    end
  end

  def validate_json_shapes
    %i[resource_scope normalized_arguments decisive_rule].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
    %i[effects policy_chain requested_durations].each do |attribute|
      errors.add(attribute, "must be a JSON array") unless public_send(attribute).is_a?(Array)
    end
    unknown = Array(requested_durations).map(&:to_s) - DURATIONS
    errors.add(:requested_durations, "contains unsupported durations") if unknown.any?
  end

  def validate_decision
    decided = state.in?(%w[approved denied])
    errors.add(:decision_principal, "is required for a decision") if decided && decision_principal.nil?
    errors.add(:decided_at, "is required for a decision") if decided && decided_at.nil?
  end

  def validate_operation_item
    return unless kind == "operation"

    errors.add(:operation, "is required") if operation.blank?
    errors.add(:operation_version, "is required") if operation_version.blank?
    errors.add(:invocation_fingerprint, "is required") if invocation_fingerprint.blank?
  end

  def validate_prerequisites_belong_to_request
    return unless chat_pending_action_id

    errors.add(:prerequisites, "must belong to the same pending action") if prerequisites.any? { |item| item.chat_pending_action_id != chat_pending_action_id }
  end

  def record_creation_transition!
    transitions.create!(chat_pending_action: chat_pending_action, event_type: "created", to_state: state, metadata: {})
  end

  def record_state_transition!
    from, to = saved_change_to_state
    transitions.create!(chat_pending_action: chat_pending_action, event_type: "state_changed", from_state: from, to_state: to, actor: decision_principal, metadata: {})
  end
end
