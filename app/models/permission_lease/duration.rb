class PermissionLease::Duration
  TYPES = {
    "invocation" => "PermissionLease::Duration::Invocation",
    "chat_session" => "PermissionLease::Duration::ChatSessionScope",
    "job" => "PermissionLease::Duration::JobScope"
  }.freeze

  def self.for(kind, lease)
    TYPES.fetch(kind).constantize.new(lease)
  end

  def initialize(lease)
    @lease = lease
  end

  def validate(_record) = raise NotImplementedError
  def available?(context:, fingerprint:) = raise NotImplementedError
end

class PermissionLease::Duration::Invocation < PermissionLease::Duration
  def validate(record)
    record.errors.add(:invocation_fingerprint, "is required") if record.invocation_fingerprint.blank?
    record.errors.add(:max_uses, "must be one") unless record.max_uses == 1
    record.errors.add(:chat_session, "must be blank") if record.chat_session_id.present?
    record.errors.add(:job, "must be blank") if record.job_id.present?
  end

  def available?(context:, fingerprint:)
    fingerprint.present? && ActiveSupport::SecurityUtils.secure_compare(@lease.invocation_fingerprint, fingerprint)
  end
end

class PermissionLease::Duration::ChatSessionScope < PermissionLease::Duration
  def validate(record)
    record.errors.add(:chat_session, "is required") if record.chat_session_id.blank?
    record.errors.add(:chat_session, "must be active") if record.chat_session&.deleted_at?
    record.errors.add(:job, "must be blank") if record.job_id.present?
    record.errors.add(:invocation_fingerprint, "must be blank") if record.invocation_fingerprint.present?
  end

  def available?(context:, fingerprint:)
    @lease.chat_session.present? && @lease.chat_session.deleted_at.nil? &&
      context[:chat_session_id].to_i == @lease.chat_session_id
  end
end

class PermissionLease::Duration::JobScope < PermissionLease::Duration
  def validate(record)
    record.errors.add(:job, "is required") if record.job_id.blank?
    record.errors.add(:job, "must not be terminal") if record.job&.state.in?(Job::TERMINAL_STATES)
    record.errors.add(:chat_session, "must be blank") if record.chat_session_id.present?
    record.errors.add(:invocation_fingerprint, "must be blank") if record.invocation_fingerprint.present?
  end

  def available?(context:, fingerprint:)
    @lease.job.present? && !@lease.job.state.in?(Job::TERMINAL_STATES) &&
      context[:job_id].to_i == @lease.job_id
  end
end
