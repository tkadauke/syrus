class MacosWorkerDrain < ApplicationRecord
  ACTIVE_STATES = %w[draining updating failed].freeze
  TERMINAL_STATES = %w[completed].freeze
  DRAINING = "draining".freeze
  UPDATING = "updating".freeze
  FAILED = "failed".freeze
  COMPLETED = "completed".freeze

  before_validation :default_payloads

  validates :state, presence: true
  validate :identity_present

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :blocking_admission, -> { where(state: %w[draining updating]) }

  def self.for_identity(worker_storage_key: nil, hostname: nil)
    key = worker_storage_key.to_s.presence
    host = hostname.to_s.presence
    return none if key.blank? && host.blank?

    predicates = []
    values = {}
    if key
      predicates << "worker_storage_key = :worker_storage_key"
      values[:worker_storage_key] = key
    end
    if host
      predicates << "hostname = :hostname"
      values[:hostname] = host
    end

    where(predicates.join(" OR "), values)
  end

  def self.admission_blocked?(worker_storage_key: nil, hostname: nil)
    blocking_admission.merge(for_identity(worker_storage_key: worker_storage_key, hostname: hostname)).exists?
  end

  def self.active_by_identity
    active.each_with_object({}) do |drain, memo|
      memo[drain.worker_storage_key] = drain if drain.worker_storage_key.present?
      memo[drain.hostname] = drain if drain.hostname.present?
    end
  end

  def active?
    ACTIVE_STATES.include?(state)
  end

  def blocking_admission?
    state.in?(%w[draining updating])
  end

  def force_termination_requested?
    force_terminate_at.present?
  end

  def directive_payload
    {
      state: state,
      worker_storage_key: worker_storage_key,
      hostname: hostname,
      desired_git_sha: desired_git_sha,
      desired_version: desired_version || {},
      force_terminate: force_termination_requested?,
      drain_started_at: drain_started_at&.iso8601,
      update_started_at: update_started_at&.iso8601,
      failed_at: failed_at&.iso8601,
      completed_at: completed_at&.iso8601,
      last_error: last_error,
      metadata: metadata || {}
    }.compact
  end

  private

  def default_payloads
    self.state ||= DRAINING
    self.desired_version ||= {}
    self.metadata ||= {}
  end

  def identity_present
    return if worker_storage_key.present? || hostname.present?

    errors.add(:base, "worker_storage_key or hostname must be present")
  end
end
