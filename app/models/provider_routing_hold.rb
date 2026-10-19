class ProviderRoutingHold < ApplicationRecord
  STATUSES = %w[ active cleared released overridden ].freeze
  RESUMPTION_MODES = %w[ when_conditions_clear until_time manual ].freeze
  RELEASE_KINDS = %w[ conditions_cleared time_elapsed manual override ].freeze

  belongs_to :workflow
  belongs_to :step, optional: true
  belongs_to :provider_routing_rule, optional: true
  belongs_to :released_by_user, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :resumption_mode, inclusion: { in: RESUMPTION_MODES }
  validates :reason, :condition_evidence, :matched_scope, presence: true
  validates :release_kind, inclusion: { in: RELEASE_KINDS }, allow_nil: true
  validates :next_reevaluation_at, presence: true, if: -> { resumption_mode == "until_time" }

  scope :active, -> { where(status: "active") }
  scope :automatic, -> { active.where(resumption_mode: %w[when_conditions_clear until_time]) }
  scope :due, ->(now = Time.current) { automatic.where(next_reevaluation_at: ..now) }

  def active? = status == "active"
end
