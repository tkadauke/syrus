class WorkflowStepWorkerSlot < ApplicationRecord
  Acquisition = Data.define(:acquired, :reason, :delay, :details) do
    def acquired? = acquired
    def deferred? = !acquired
  end

  RETRY_DELAY = 30.seconds

  belongs_to :workflow
  belongs_to :step
  belongs_to :run

  scope :active, -> { where(released_at: nil) }

  before_validation :set_acquired_at, on: :create
  before_validation :sync_active_slot_key

  validates :worker_key, :acquired_at, presence: true
  validates :active_slot_key, uniqueness: true, allow_blank: true

  def self.enabled?
    AppSetting.workflow_step_worker_slot_admission_enabled?
  end

  def self.acquire_for(run)
    return acquired("disabled", run: run) unless enabled?
    return acquired("terminal_run", run: run) if run.terminal?

    workflow = run.workflow
    step = run.step
    identity = worker_identity
    return acquired("missing_execution_graph", run: run) unless workflow && step
    return acquired("missing_worker_identity", run: run, identity: identity) if identity[:worker_key].blank?

    release_dead_worker_slots!(identity)

    create!(
      workflow: workflow,
      step: step,
      run: run,
      worker_key: identity.fetch(:worker_key),
      worker_hostname: identity[:hostname],
      worker_storage_key: identity[:storage_key]
    )
    acquired("worker_slot_acquired", run: run, identity: identity)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    deferred("worker_slot_busy", run: run, identity: identity)
  end

  def self.release_for_run!(run, reason: "run_terminal")
    active.where(run_id: run.id).find_each { |slot| slot.release!(reason: reason) }
  end

  def self.release_dead_worker_slots!(identity = worker_identity)
    worker_key = identity[:worker_key].presence
    return if worker_key.blank?

    active.where(worker_key: worker_key).find_each do |slot|
      slot.release!(reason: "worker_dead") unless slot.worker_live?
    end
  end

  def self.worker_identity
    storage_key = WorkerStorageIdentity.queue_key.presence
    hostname = SyrusVersion.hostname.to_s.presence
    worker_key = if storage_key.present?
                   "storage:#{storage_key}"
                 elsif hostname.present?
                   "host:#{hostname}"
                 end

    { worker_key: worker_key, hostname: hostname, storage_key: storage_key }
  end

  def self.acquired(reason, run:, identity: worker_identity)
    Acquisition.new(acquired: true, reason: reason, delay: nil, details: details(run, identity, reason))
  end

  def self.deferred(reason, run:, identity: worker_identity)
    Acquisition.new(acquired: false, reason: reason, delay: RETRY_DELAY, details: details(run, identity, reason))
  end

  def self.details(run, identity, reason)
    {
      "reason" => reason,
      "worker_key" => identity[:worker_key],
      "worker_hostname" => identity[:hostname],
      "worker_storage_key" => identity[:storage_key],
      "workflow_id" => run.workflow_id,
      "step_id" => run.step_id,
      "step_kind" => run.step&.kind,
      "run_id" => run.id
    }.compact
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
