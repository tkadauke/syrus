class PrReviewComment < ApplicationRecord
  PR_TYPES = %w[ direct upstream fork_review ].freeze
  COMMENT_KINDS = %w[ issue review ].freeze
  ATTRIBUTED_TOS = %w[ job_owner member external ].freeze

  belongs_to :job

  validates :pr_type, presence: true, inclusion: { in: PR_TYPES }
  validates :comment_kind, presence: true, inclusion: { in: COMMENT_KINDS }
  validates :github_comment_id, presence: true
  validates :attributed_to, inclusion: { in: ATTRIBUTED_TOS }, allow_nil: true
  validates :github_comment_id, uniqueness: {
    scope: [ :job_id, :pr_type, :comment_kind ],
    message: "has already been recorded for this job/PR/kind combination"
  }

  scope :actionable_comments, -> { where(actionable: true) }
  scope :unactioned, -> { where(actioned_at: nil) }
  scope :for_pr_type, ->(type) { where(pr_type: type) }
  scope :job_owner_comments, -> { where(attributed_to: "job_owner") }
  scope :member_comments, -> { where(attributed_to: "member") }
  scope :external_comments, -> { where(attributed_to: "external") }

  def job_owner? = attributed_to == "job_owner"
  def member? = attributed_to == "member"
  def external? = attributed_to == "external"
  def actioned? = actioned_at.present?

  def mark_actioned!(by:)
    update!(actioned_at: Time.current, actioned_by: by)
  end
end
