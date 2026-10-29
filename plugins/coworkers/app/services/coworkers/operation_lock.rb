class Coworkers::OperationLock
  class Busy < StandardError; end

  WORK_DEFINITION_KIND = "initial"

  def self.with(coworker, &block) = new(coworker).with(&block)

  def initialize(coworker)
    @coworker = coworker
  end

  def with
    @coworker.class.transaction do
      @coworker.class.lock.find(@coworker.id)
      chats = lock_chats
      raise Busy, "coworker has work in flight" if chats.any?(&:turn_in_flight?)

      intent, unit, lock = acquire_run_lock!
      result = yield
      # These rows are a transaction-scoped lease, not a workflow attempt.
      # Keeping them uncommitted until the operation finishes makes the same
      # unique lock key serialize a newly starting WorkUnit at the database.
      lock.destroy!
      unit.destroy!
      intent.destroy!
      result
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    raise unless lock_conflict?(error)

    raise Busy, "coworker has work in flight"
  end

  private

  def lock_chats
    ChatSession
      .where(id: @coworker.coworker_chats.select(:chat_session_id))
      .order(:id)
      .lock
      .load
  end

  def acquire_run_lock!
    intent = WorkIntent.create!(
      kind: WORK_DEFINITION_KIND,
      state: "requested",
      scope_type: "coworker_operation",
      scope_id: @coworker.id,
      actor: @coworker.owner_user,
      source_type: "coworker_operation",
      source_id: @coworker.id
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: WORK_DEFINITION_KIND,
      state: "running",
      scope_type: "coworker_operation",
      scope_id: @coworker.id,
      started_at: Time.current
    )
    lock = unit.work_unit_locks.create!(lock_key: lock_key)
    [ intent, unit, lock ]
  end

  def lock_key = "coworker:#{@coworker.id}"

  def lock_conflict?(error)
    return true if error.is_a?(ActiveRecord::RecordNotUnique)

    error.record.is_a?(WorkUnitLock) && error.record.errors[:active_lock_key].present?
  end
end
