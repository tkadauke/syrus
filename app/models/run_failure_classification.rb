class RunFailureClassification < ApplicationRecord
  CIRCUIT_REPAIR_STATUSES = %w[false_positive inconclusive transient].freeze

  belongs_to :run
  belongs_to :repaired_by_user, class_name: "User", optional: true

  serialize :classifier_inputs, coder: JSON

  validates :classification, presence: true
  validates :classified_at, presence: true
  validates :run_id, uniqueness: true
  validates :retryable, inclusion: { in: [ true, false ] }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :repair_status, inclusion: { in: CIRCUIT_REPAIR_STATUSES }, allow_nil: true

  scope :unrepaired_for_circuit, -> { where(repair_status: nil) }

  def repaired_for_circuit? = repair_status.present?

  def mark_circuit_repair!(status:, reason:, user:)
    update!(
      repair_status: status.to_s,
      repair_reason: reason.to_s,
      repaired_at: Time.current,
      repaired_by_user: user
    )
  end

  def repair_summary
    return unless repaired_for_circuit?

    {
      status: repair_status,
      reason: repair_reason,
      repaired_at: repaired_at&.iso8601,
      repaired_by_user_id: repaired_by_user_id
    }.compact
  end
end
