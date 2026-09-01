require "digest"

class OperationalLogEvent < ApplicationRecord
  include ObservabilityEventRecord

  LEVELS = %w[ debug info warn error fatal unknown ].freeze
  RETENTION = 6.hours
  EVENT_UID_FIELDS = %i[
    occurred_at
    level
    role
    hostname
    app_revision
    pid
    source
    request_id
    job_id
    workflow_id
    run_id
    message
    context
  ].freeze

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
        batch.each do |row|
          id = persist_idempotently!(row)
          ids << id if id
        end
      ensure
        Current.suppress_operational_log_index_enqueue = previous
      end

      ids.uniq!
      IndexOperationalLogEventsJob.perform_later(ids) if ids.present? && OperationalLogging.configured_for_instance?
    end
  end

  def self.from_event_hash(event)
    attrs = event.to_h
    occurred_at = parse_event_time(attrs["occurred_at"]) || Time.current
    context = normalized_event_json(attrs["context"])
    {
      event_uid: attrs["event_uid"].presence || event_uid_for(attrs.merge("occurred_at" => occurred_at, "context" => context)),
      occurred_at: occurred_at,
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
      context: context,
      created_at: Time.current,
      updated_at: Time.current
    }.compact
  end

  def self.event_uid_for(attrs)
    payload = EVENT_UID_FIELDS.index_with do |key|
      value = event_attr(attrs, key)
      value = parse_event_time(value)&.iso8601(6) if key == :occurred_at
      value = normalized_event_json(value) if key == :context
      value
    end
    Digest::SHA256.hexdigest(JSON.generate(canonical_event_value(payload)))
  end

  def self.canonical_event_value(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.index_with { |key| canonical_event_value(event_attr(value, key)) }
    when Array
      value.map { |entry| canonical_event_value(entry) }
    else
      value
    end
  end

  def self.event_attr(attrs, key)
    string_key = key.to_s
    return attrs[string_key] if attrs.key?(string_key)

    attrs[key.to_sym]
  end

  def self.persist_idempotently!(row)
    uid = row[:event_uid].presence
    return create!(row).id if uid.blank?

    where(event_uid: uid).pick(:id) || create!(row).id
  rescue ActiveRecord::RecordNotUnique
    where(event_uid: uid).pick(:id) if uid.present?
  end
  private_class_method :canonical_event_value, :event_attr, :persist_idempotently!

  private

  def enqueue_index
    return if Current.suppress_operational_log_index_enqueue
    return unless OperationalLogging.configured_for_instance?

    IndexOperationalLogEventJob.perform_later(id)
  end
end
