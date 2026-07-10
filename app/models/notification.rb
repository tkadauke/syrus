class Notification < ApplicationRecord
  KINDS = %w[job_failed job_implemented pr_comment_addressed pr_merged epic_completed upstream_pr_closed main_broken main_recovered].freeze

  belongs_to :user
  belongs_to :job, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :body, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
end
