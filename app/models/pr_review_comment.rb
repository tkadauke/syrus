class PrReviewComment < ApplicationRecord
  PR_TYPES = %w[ direct upstream fork_review external ].freeze
  COMMENT_KINDS = %w[ issue review ].freeze
  ATTRIBUTED_TOS = %w[ job_owner member external ].freeze
  HANDLING_STATES = %w[ pending active failed handled ignored ].freeze

  belongs_to :job
  belongs_to :handling_workflow, class_name: "Workflow", optional: true

  validates :pr_type, presence: true, inclusion: { in: PR_TYPES }
  validates :comment_kind, presence: true, inclusion: { in: COMMENT_KINDS }
  validates :github_comment_id, presence: true
  validates :attributed_to, inclusion: { in: ATTRIBUTED_TOS }, allow_nil: true
  validates :handling_state, inclusion: { in: HANDLING_STATES }, allow_nil: true
  validates :github_comment_id, uniqueness: {
    scope: [ :job_id, :pr_type, :comment_kind ],
    message: "has already been recorded for this job/PR/kind combination"
  }

  scope :actionable_comments, -> { where(actionable: true) }
  scope :unactioned, -> { where(actioned_at: nil) }
  scope :not_ignored, -> { where(ignored_at: nil).where.not(handling_state: "ignored") }
  scope :for_pr_type, ->(type) { where(pr_type: type) }
  scope :job_owner_comments, -> { where(attributed_to: "job_owner") }
  scope :member_comments, -> { where(attributed_to: "member") }
  scope :external_comments, -> { where(attributed_to: "external") }

  def job_owner? = attributed_to == "job_owner"
  def member? = attributed_to == "member"
  def external? = attributed_to == "external"
  def actioned? = actioned_at.present?
  def handled? = handled_at.present? || handling_state == "handled"
  def ignored? = ignored_at.present? || actioned_by == "operator:ignore" || handling_state == "ignored"
  def handling_active?
    handling_workflow&.state.in?(%w[queued running]) || handling_state == "active"
  end
  def handling_failed? = handling_state == "failed"

  def pending_for_operator?
    return false unless actionable?
    return false if job_owner?
    return false if ignored? || handled?
    return false if handling_active?

    actioned_at.blank? || handling_failed?
  end

  def retryable_handling?
    return false if ignored? || handled? || handling_active?

    handling_failed? && handling_workflow_id.present?
  end

  def mark_actioned!(by:)
    mark_ignored!(by: by) if by == "operator:ignore"
    mark_handled!(by: by) unless by == "operator:ignore"
  end

  def mark_handling_started!(workflow:, by:)
    update!(
      handling_workflow: workflow,
      handling_state: "active",
      handling_started_at: Time.current,
      handling_failed_at: nil,
      handling_failure_reason: nil,
      handled_at: nil,
      actioned_by: by
    )
  end

  def mark_handled!(by: actioned_by.presence || "workflow")
    now = Time.current
    update!(
      handling_state: "handled",
      handled_at: now,
      actioned_at: now,
      actioned_by: by,
      handling_failed_at: nil,
      handling_failure_reason: nil
    )
  end

  def mark_handling_failed!(reason:)
    update!(
      handling_state: "failed",
      handling_failed_at: Time.current,
      handling_failure_reason: reason.presence,
      handled_at: nil,
      actioned_at: nil
    )
  end

  def mark_ignored!(by: "operator:ignore")
    now = Time.current
    update!(
      handling_state: "ignored",
      ignored_at: now,
      actioned_at: now,
      actioned_by: by,
      handling_failed_at: nil,
      handling_failure_reason: nil
    )
  end
end
