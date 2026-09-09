class WorkflowStepWorkerSlot < ApplicationRecord
  STALE_INACTIVE_GRACE = 2.minutes

  belongs_to :run
  belongs_to :workflow
  belongs_to :step

  scope :active, -> { where(released_at: nil) }

  before_validation :set_acquired_at, on: :create
  before_validation :sync_active_slot_key

  validates :run, :workflow, :step, presence: true
  validates :worker_hostname, :slot_key, :slot_key_source, presence: true
  validates :active_slot_key, uniqueness: true, allow_nil: true

  class Conflict < StandardError; end

  def self.acquire!(run:, hostname:, storage_key:)
    slot_key = storage_key.presence || hostname
    slot_key_source = storage_key.present? ? "worker_storage_key" : "hostname"

    create!(
      run: run,
      workflow: run.workflow,
      step: run.step,
      worker_hostname: hostname,
      worker_storage_key: storage_key,
      slot_key: slot_key,
      slot_key_source: slot_key_source,
      acquired_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    raise Conflict, "worker step slot #{slot_key.inspect} is already active"
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.of_kind?(:active_slot_key, :taken)

    raise Conflict, "worker step slot #{slot_key.inspect} is already active"
  end

  def self.release_for_run!(run, reason:)
    active.where(run_id: run.id).find_each { |slot| slot.release!(reason: reason) }
  end

  def self.release_inactive_holders!(reason: "inactive_run")
    active
      .joins(:run)
      .where.not(runs: { state: "running" })
      .where("workflow_step_worker_slots.acquired_at < ?", STALE_INACTIVE_GRACE.ago)
      .find_each do |slot|
        slot.release!(reason: reason)
      end
  end

  def release!(reason:)
    update!(released_at: released_at || Time.current, release_reason: reason, active_slot_key: nil)
    self
  end

  private

  def set_acquired_at
    self.acquired_at ||= Time.current
  end

  def sync_active_slot_key
    self.active_slot_key = released_at.present? ? nil : slot_key
  end
end
