class WorkflowWarning < ApplicationRecord
  SEVERITIES = %w[low medium high].freeze
  STATES = %w[pending dismissed].freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :step, optional: true
  belongs_to :created_job, class_name: "Job", optional: true

  validates :kind, presence: true
  validates :title, presence: true
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :state, presence: true, inclusion: { in: STATES }

  scope :pending, -> { where(state: "pending") }
  scope :dismissed, -> { where(state: "dismissed") }

  def pending? = state == "pending"
  def dismissed? = state == "dismissed"

  def dismiss!
    with_lock do
      return false unless pending?

      update!(state: "dismissed")
      true
    end
  end

  # Stamps the Job filed from this warning's (possibly edited) suggested_prompt.
  # Filing is allowed regardless of pending/dismissed state and doesn't itself
  # change state — a warning can be dismissed after a fix Job was already filed.
  def file_fix_job!(created_job)
    with_lock { update!(created_job: created_job) }
  end

  def redacted_title = CommandRedactor.redact(title)
  def redacted_suggested_prompt = suggested_prompt.nil? ? nil : CommandRedactor.redact(suggested_prompt)
  def redacted_evidence = CommandRedactor.redact_value(evidence)
end
