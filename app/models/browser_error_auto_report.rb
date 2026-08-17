class BrowserErrorAutoReport < ApplicationRecord
  STATUSES = %w[ pending reported failed ].freeze

  belongs_to :browser_error_event
  belongs_to :user
  belongs_to :job, optional: true

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :app_revision, :fingerprint, :status, presence: true
  validates :fingerprint, uniqueness: { scope: :app_revision }

  def self.claim_for!(event)
    create!(
      browser_error_event: event,
      user: event.user,
      app_revision: event.app_revision.presence || "unknown",
      fingerprint: event.fingerprint
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end
end
