class OperationalLogEvent < ApplicationRecord
  include ObservabilityEventRecord

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

  def self.persist_observability_events!(rows, batch_size:)
    rows.each_slice(batch_size) do |batch|
      ids = []
      previous = Current.suppress_operational_log_index_enqueue
      Current.suppress_operational_log_index_enqueue = true
      begin
        batch.each { |row| ids << create!(row).id }
      ensure
        Current.suppress_operational_log_index_enqueue = previous
      end

      IndexOperationalLogEventsJob.perform_later(ids) if ids.present? && OperationalLogging.configured_for_instance?
    end
  end

  def self.from_event_hash(event)
    attrs = event.to_h
    {
      occurred_at: parse_event_time(attrs["occurred_at"]) || Time.current,
      level: attrs["level"],
      role: attrs["role"],
      hostname: attrs["hostname"],
      app_revision: attrs["app_revision"],
      pid: attrs["pid"],
      source: attrs["source"],
      request_id: attrs["request_id"],
      job_id: attrs["job_id"],
      workflow_id: attrs["workflow_id"],
      run_id: attrs["run_id"],
      message: attrs["message"],
      context: attrs["context"] || {},
      created_at: Time.current,
      updated_at: Time.current
    }.compact
  end

  private

  def enqueue_index
    return if Current.suppress_operational_log_index_enqueue
    return unless OperationalLogging.configured_for_instance?

    IndexOperationalLogEventJob.perform_later(id)
  end
end
