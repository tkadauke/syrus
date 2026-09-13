class WorkflowStepWorkerSlot < ApplicationRecord
  # Historical rows from the removed strict per-worker mutex. New run
  # admission is handled by RunHostAdmission; keep this model so old workflow
  # diagnostics can still render and terminal callbacks can release pre-removal
  # active slots after a rolling deploy.
  belongs_to :workflow
  belongs_to :step
  belongs_to :run

  scope :active, -> { where(released_at: nil) }

  before_validation :set_acquired_at, on: :create
  before_validation :sync_active_slot_key

  validates :worker_key, :acquired_at, presence: true
  validates :active_slot_key, uniqueness: true, allow_blank: true

  def self.release_for_run!(run, reason: "run_terminal")
    active.where(run_id: run.id).find_each { |slot| slot.release!(reason: reason) }
  end

  def release!(reason: "released")
    update!(released_at: released_at || Time.current, release_reason: reason, active_slot_key: nil)
  end

  def worker_live?
    if worker_storage_key.present?
      return InstanceVersion.worker_queue_live?(Workflow.resume_queue_name(worker_storage_key))
    end

    InstanceVersion.worker_live?(worker_hostname)
  end

  def active?
    released_at.nil?
  end

  private

  def set_acquired_at
    self.acquired_at ||= Time.current
  end

  def sync_active_slot_key
    self.active_slot_key = released_at.present? ? nil : worker_key
  end
end
