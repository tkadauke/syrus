class WorkflowPhaseAdmissionJob < ApplicationJob
  queue_as :control_plane

  DEDUPE_TTL_BUFFER = 30.seconds
  MIN_DEDUPE_TTL = 30.seconds

  discard_on ActiveRecord::RecordNotFound

  def self.enqueue_once(workflow_id, step_id = nil, wait: nil, wait_until: nil, priority: nil, force: false)
    return false if workflow_id.blank?

    if !force && duplicate_suppressed?(workflow_id, step_id, wait: wait, wait_until: wait_until)
      return false
    end

    options = {}
    options[:priority] = priority if priority.present?
    options[:wait_until] = wait_until if wait_until.present?
    options[:wait] = wait if wait.present? && wait_until.blank?
    scheduler = options.any? ? set(**options) : self
    args = step_id.present? ? [ workflow_id, step_id ] : [ workflow_id ]
    scheduler.perform_later(*args)
    true
  end

  def perform(workflow_id, step_id = nil)
    WorkUnits::DeferredPhaseResume.call(workflow_id, step_id)
  end

  def self.duplicate_suppressed?(workflow_id, step_id, wait:, wait_until:)
    key = dedupe_key(workflow_id, step_id)
    return true if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: dedupe_ttl(wait: wait, wait_until: wait_until))
    false
  rescue StandardError => e
    Rails.logger.warn("[WorkflowPhaseAdmissionJob] dedupe unavailable: #{e.class}: #{e.message}")
    false
  end
  private_class_method :duplicate_suppressed?

  def self.dedupe_key(workflow_id, step_id)
    "workflow_phase_admission:v1:#{workflow_id}:#{step_id.presence || 'workflow'}"
  end
  private_class_method :dedupe_key

  def self.dedupe_ttl(wait:, wait_until:)
    delay = if wait_until.present?
      wait_until - Time.current
    elsif wait.present?
      wait
    else
      0.seconds
    end

    [ delay.to_f.seconds + DEDUPE_TTL_BUFFER, MIN_DEDUPE_TTL ].max
  end
  private_class_method :dedupe_ttl
end
