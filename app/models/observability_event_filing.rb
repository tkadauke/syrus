class ObservabilityEventFiling < ApplicationRecord
  MODES = %w[ direct_job github_issue ].freeze

  belongs_to :user
  belongs_to :job, optional: true

  validates :event_type, :event_id, :mode, presence: true
  validates :mode, inclusion: { in: MODES }

  def filed?
    job.present? || issue_url.present?
  end
end
