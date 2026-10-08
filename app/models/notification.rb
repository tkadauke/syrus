class Notification < ApplicationRecord
  include HasConfigurableRetention

  KINDS = %w[
    job_failed job_implemented pr_comment_addressed pr_merged epic_completed upstream_pr_closed
    main_broken main_inconclusive main_recovered external_pr_feedback investigation_escalated
  ].freeze

  belongs_to :user
  belongs_to :job, optional: true
  belongs_to :repository, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :body, presence: true
  validates :dedupe_key, length: { maximum: 191 }, allow_nil: true

  configurable_retention setting_key: :notification_retention_days, unit: :days

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("created_at < ?", cutoff) : none
  }
end
