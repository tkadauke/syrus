class InsightSuggestion < ApplicationRecord
  SEVERITIES = %w[low medium high].freeze
  STATES     = %w[pending accepted dismissed].freeze

  belongs_to :job
  belongs_to :repository
  belongs_to :created_job, class_name: "Job", optional: true

  validates :title,      presence: true
  validates :category,   presence: true
  validates :severity,   presence: true, inclusion: { in: SEVERITIES }
  validates :confidence, presence: true,
                         numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :state,      presence: true, inclusion: { in: STATES }

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

  def pending?    = state == "pending"
  def accepted?   = state == "accepted"
  def dismissed?  = state == "dismissed"
end
