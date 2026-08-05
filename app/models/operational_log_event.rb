class OperationalLogEvent < ApplicationRecord
  LEVELS = %w[ debug info warn error fatal unknown ].freeze
  RETENTION = 6.hours

  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true

  attribute :context, :json, default: -> { {} }

  validates :occurred_at, :level, :role, :hostname, :source, :message, presence: true
  validates :level, inclusion: { in: LEVELS }

  after_commit :enqueue_index, on: :create

  scope :expired, -> { where(occurred_at: ...RETENTION.ago) }

  private

  def enqueue_index
    return unless OperationalLogging.configured_for_instance?

    IndexOperationalLogEventJob.perform_later(id)
  end
end
