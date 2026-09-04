# One thing a person has to decide (workflow-engine-v3 B2).
#
# Today the unit of attention is a Job: the `inbox` preset unions unread
# feedback, failed jobs, landing failures, needs-review and awaiting-approval,
# and the operator reconstructs the problem from workflow state and logs.
#
# A Decision is the problem instead -- its evidence, the verdict rung 0
# reached, and one to three typed actions bound to the existing PendingActions
# mechanism. The actions are not new capabilities; they are the ones an
# operator already has, attached to the thing that needs deciding.
#
# `queue` exists because bug triage needs a second queue on the same mechanism:
# different audience, different SLA, different actions. Merging them buries the
# rare important decision under the frequent cheap one.
class Decision < ApplicationRecord
  STATES = %w[open decided expired superseded].freeze
  QUEUES = %w[operator triage].freeze
  URGENCIES = %w[low normal urgent].freeze
  RESOLUTIONS = %w[upheld dismissed deferred].freeze

  belongs_to :user, optional: true
  belongs_to :repository, optional: true
  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :decided_by_user, class_name: "User", optional: true

  validates :problem_code, :signature, :title, presence: true
  validates :state, inclusion: { in: STATES }
  validates :queue, inclusion: { in: QUEUES }
  validates :urgency, inclusion: { in: URGENCIES }
  validates :resolution, inclusion: { in: RESOLUTIONS }, allow_nil: true
  validate :problem_code_is_known
  validate :actions_are_known_pending_actions

  after_initialize :seed_json_columns, if: :new_record?

  scope :open_decisions, -> { where(state: "open") }
  scope :for_queue, ->(queue) { where(queue: queue.to_s) }
  scope :unexpired, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  # The two queues are routed separately on purpose (workflow-engine-v3 C3):
  # different audience, different SLA, different actions. Merging them would
  # bury the rare important decision under the frequent cheap one.
  scope :operator_queue, -> { for_queue("operator") }
  scope :triage_queue, -> { for_queue("triage") }

  # Most urgent first, then oldest -- within one queue. Deliberately not a
  # cross-queue ordering: an urgent triage item is not more important than an
  # urgent landing failure, it is a different person's problem.
  scope :in_attention_order, lambda {
    order(Arel.sql("CASE urgency WHEN 'urgent' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END"), created_at: :asc)
  }

  def self.queue_summary(queue)
    scope = for_queue(queue).open_decisions.unexpired
    { queue: queue.to_s, open: scope.count, by_urgency: scope.group(:urgency).count }
  end

  def problem = Problem.new(problem_code, evidence: evidence.to_h.symbolize_keys)

  def open? = state == "open"
  def decided? = state == "decided"

  # Actions are `{ "action_key" => ..., "label" => ..., "payload" => {...} }`,
  # naming entries in the PendingActions registry rather than new verbs.
  def action_keys = Array(actions).filter_map { |action| action.is_a?(Hash) ? action["action_key"] : nil }

  def decide!(resolution:, user: nil, reason: nil)
    raise ArgumentError, "unknown resolution=#{resolution.inspect}" unless RESOLUTIONS.include?(resolution.to_s)

    update!(
      state: "decided",
      resolution: resolution.to_s,
      reason: reason,
      decided_by_user: user,
      decided_at: Time.current
    )
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  private

  def seed_json_columns
    self.evidence ||= {}
    self.actions ||= []
  end

  def problem_code_is_known
    return if problem_code.blank?
    return if Problem::Kind.exists?(problem_code)

    errors.add(:problem_code, "is not a known Problem::Kind")
  end

  # A decision offering an action nobody can execute is worse than one with no
  # actions at all: it reads as answerable and is not.
  def actions_are_known_pending_actions
    action_keys.each do |key|
      PendingActions.for(key)
    rescue PendingActions::UnknownAction
      errors.add(:actions, "names unknown pending action #{key.inspect}")
    end
  end
end
