class InsightSuggestion < ApplicationRecord
  SEVERITIES = %w[low medium high].freeze
  STATES     = %w[pending accepted dismissed].freeze
  PROPOSAL_TYPES = %w[create_job save_memory remove_memory revise_existing_insight informational].freeze

  belongs_to :job
  belongs_to :repository
  belongs_to :created_job, class_name: "Job", optional: true
  belongs_to :target_memory, class_name: "ChatMemory", optional: true
  belongs_to :target_insight, class_name: "InsightSuggestion", optional: true
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
  validate :remove_memory_targets_memory
  validate :revision_targets_insight

  scope :pending,   -> { where(state: "pending") }
  scope :accepted,  -> { where(state: "accepted") }
  scope :dismissed, -> { where(state: "dismissed") }
  scope :for_repository, ->(repository) { where(repository: repository) }

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

  def pending?    = state == "pending"
  def accepted?   = state == "accepted"
  def dismissed?  = state == "dismissed"

  def effective_proposal_type
    return proposal_type if proposal_type.present? && proposal_type != "informational"
    return "create_job" if suggested_prompt.present?
    return "save_memory" if memory_suggestion.present?

    "informational"
  end

  def remove_memory? = effective_proposal_type == "remove_memory"
  def revise_existing_insight? = effective_proposal_type == "revise_existing_insight"

  private

  def remove_memory_targets_memory
    return unless remove_memory?

    errors.add(:target_memory, "must be present for remove_memory proposals") if target_memory_id.blank?
  end

  def revision_targets_insight
    return unless revise_existing_insight?

    errors.add(:target_insight, "must be present for revise_existing_insight proposals") if target_insight_id.blank?
  end
end
