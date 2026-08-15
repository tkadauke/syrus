class InsightSuggestion < ApplicationRecord
  SEVERITIES = %w[low medium high].freeze
  STATES     = %w[pending accepted dismissed retired].freeze
  PROPOSAL_TYPES = %w[create_job save_memory remove_memory revise_existing_insight informational].freeze

  belongs_to :job
  belongs_to :repository
  belongs_to :created_job, class_name: "Job", optional: true
  belongs_to :target_memory, class_name: "ChatMemory", optional: true
  belongs_to :target_insight, class_name: "InsightSuggestion", optional: true
  belongs_to :superseded_by_insight, class_name: "InsightSuggestion", optional: true
  belongs_to :superseded_by_job, class_name: "Job", optional: true
  has_many :audit_events, class_name: "InsightSuggestionAuditEvent", dependent: :destroy

  validates :title,      presence: true
  validates :category,   presence: true
  validates :severity,   presence: true, inclusion: { in: SEVERITIES }
  validates :confidence, presence: true,
                         numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :state,      presence: true, inclusion: { in: STATES }
  validates :proposal_type, presence: true, inclusion: { in: PROPOSAL_TYPES }
  validates :stale_memory_text, length: { maximum: ChatMemory::CONTENT_MAX_LENGTH }, allow_blank: true
  validates :stale_memory_evidence, presence: true, if: :remove_memory?
  validates :retired_reason, presence: true, if: :retired?
  validate :remove_memory_targets_memory
  validate :revision_targets_insight
  validate :superseded_by_insight_not_self

  scope :pending,   -> { where(state: "pending") }
  scope :accepted,  -> { where(state: "accepted") }
  scope :dismissed, -> { where(state: "dismissed") }
  scope :retired,   -> { where(state: "retired") }
  scope :active,    -> { where.not(state: "retired") }
  scope :for_repository, ->(repository) { where(repository: repository) }
  scope :pending_remove_memory, -> { pending.where(proposal_type: "remove_memory") }

  def self.resolve_obsolete_remove_memory!(relation = all)
    relation
      .pending_remove_memory
      .left_joins(:target_memory)
      .where("chat_memories.id IS NULL OR chat_memories.deleted_at IS NOT NULL")
      .find_each(&:accept_obsolete_remove_memory!)
  end

  # Operator accepted the suggestion — optionally records the Job it promoted into.
  def accept!(created_job: nil)
    with_lock do
      return false unless pending?

      update!(state: "accepted", accepted_at: Time.current, created_job: created_job)
      true
    end
  end

  def dismiss!
    with_lock do
      return false unless pending?

      update!(state: "dismissed", dismissed_at: Time.current)
      true
    end
  end

  def undismiss!
    with_lock do
      return false unless dismissed?

      update!(state: "pending", dismissed_at: nil)
      true
    end
  end

  # Audited retirement path for stale, duplicated, or superseded insights.
  # Pending/dismissed insights retire directly; accepted insights are
  # operator history and are refused unless retire_accepted: true is passed
  # explicitly (a distinct, deliberate override path).
  def retire!(reason:, actor: nil, superseded_by_insight: nil, superseded_by_job: nil, retire_accepted: false)
    with_lock do
      return false if retired?
      return false if accepted? && !retire_accepted

      previous_values = retirement_snapshot
      update!(
        state: "retired",
        retired_at: Time.current,
        retired_reason: reason,
        superseded_by_insight: superseded_by_insight,
        superseded_by_job: superseded_by_job
      )

      InsightSuggestionAuditEvent.record!(
        insight_suggestion: self,
        event_type: "retired",
        actor: actor,
        previous_values: previous_values,
        new_values: retirement_snapshot,
        reason: reason
      )
      true
    end
  end

  def pending?    = state == "pending"
  def accepted?   = state == "accepted"
  def dismissed?  = state == "dismissed"
  def retired?    = state == "retired"

  def accept_obsolete_remove_memory!
    with_lock do
      return false unless pending? && remove_memory?

      memory = target_memory
      return false if memory && !memory.deleted?

      update!(state: "accepted", accepted_at: Time.current)
      true
    end
  end

  def effective_proposal_type
    return proposal_type if proposal_type.present? && proposal_type != "informational"
    return "create_job" if suggested_prompt.present?
    return "save_memory" if memory_suggestion.present?

    "informational"
  end

  def redacted_title = redact_nullable(title)
  def redacted_category = redact_nullable(category)
  def redacted_suggested_prompt = redact_nullable(suggested_prompt)
  def redacted_memory_suggestion = redact_nullable(memory_suggestion)
  def redacted_stale_memory_text = redact_nullable(stale_memory_text)
  def redacted_stale_memory_evidence = redact_nullable(stale_memory_evidence)
  def redacted_retired_reason = redact_nullable(retired_reason)
  def redacted_evidence = CommandRedactor.redact_value(evidence)

  def remove_memory? = effective_proposal_type == "remove_memory"
  def revise_existing_insight? = effective_proposal_type == "revise_existing_insight"

  private

  def redact_nullable(value)
    value.nil? ? nil : CommandRedactor.redact(value)
  end

  def remove_memory_targets_memory
    return unless remove_memory?

    errors.add(:target_memory, "must be present for remove_memory proposals") if target_memory_id.blank?
  end

  def revision_targets_insight
    return unless revise_existing_insight?

    errors.add(:target_insight, "must be present for revise_existing_insight proposals") if target_insight_id.blank?
  end

  def superseded_by_insight_not_self
    return unless superseded_by_insight_id.present? && persisted?

    errors.add(:superseded_by_insight, "cannot reference the insight itself") if superseded_by_insight_id == id
  end

  def retirement_snapshot
    {
      "state" => state,
      "retired_at" => retired_at,
      "retired_reason" => retired_reason,
      "superseded_by_insight_id" => superseded_by_insight_id,
      "superseded_by_job_id" => superseded_by_job_id
    }
  end
end
