class WorkIntent < ApplicationRecord
  STATES = %w[requested waiting satisfied failed cancelled].freeze
  WAIT_REASONS = %w[dependency approval epic_not_ready policy_not_eligible].freeze

  belongs_to :repository, optional: true
  belongs_to :source_repository, class_name: "Repository", optional: true
  belongs_to :target_repository, class_name: "Repository", optional: true
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :superseded_by_work_intent, class_name: "WorkIntent", optional: true

  has_many :work_units, dependent: nil

  before_validation :set_requested_at, on: :create
  before_validation :normalize_wait_details
  before_validation :normalize_payload_artifacts

  validates :kind, :state, :scope_type, :requested_at, presence: true
  validates :state, inclusion: { in: STATES }
  validates :wait_reason, inclusion: { in: WAIT_REASONS }, allow_blank: true
  validates :idempotency_key, uniqueness: true, allow_blank: true

  def ready?
    requested? && wait_reason.blank? && wait_until.blank?
  end

  def wait!(reason:, wait_until: nil, details: {})
    update!(
      state: "waiting",
      wait_reason: reason,
      wait_until: wait_until,
      wait_details: details || {}
    )
  end

  def request!
    update!(
      state: "requested",
      wait_reason: nil,
      wait_until: nil,
      wait_details: {}
    )
  end

  def satisfy!
    update!(state: "satisfied", satisfied_at: satisfied_at || Time.current)
  end

  def fail!
    update!(state: "failed")
  end

  def cancel!
    update!(state: "cancelled", cancelled_at: cancelled_at || Time.current)
  end

  STATES.each do |state_name|
    define_method("#{state_name}?") { state == state_name }
  end

  def definition
    WorkDefinitions.for(kind)
  end

  def payload_artifact(key)
    (payload_artifacts || {})[key.to_s]
  end

  private

  def set_requested_at
    self.requested_at ||= Time.current
  end

  def normalize_wait_details
    self.wait_details ||= {}
  end

  def normalize_payload_artifacts
    self.payload_artifacts ||= {}
  end
end
