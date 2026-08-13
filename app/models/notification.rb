class Notification < ApplicationRecord
  KINDS = %w[
    job_failed job_implemented pr_comment_addressed pr_merged epic_completed epic_review_ready upstream_pr_closed
    epic_failed epic_feedback_queued main_broken main_inconclusive main_recovered external_pr_feedback
  ].freeze

  belongs_to :user
  belongs_to :job, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :body, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
end
