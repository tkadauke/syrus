# Serializes the final merge into one landing branch of one repository.
#
# The landing slot (`landing:repository:<id>`) is held by a landing unit from
# dispatch to merge; with a single unit per repository it makes merges mutually
# exclusive as a side effect. Once more than one landing unit may run, the merge
# itself needs its own exclusion, held only for the last sequence -- verify the
# validated base is still the branch head, handle a moved base, merge, record
# the result -- and never across grading or repair.
#
# The lock is a WorkUnitLock on the landing unit's WorkUnit under the key
# `merge:repository:<id>[:branch:<name>]`. Riding on WorkUnitLock means a lock
# whose holder is gone is released by the same machinery as stale landing
# locks: terminal units release their locks, and the reconciler repairs
# terminal units (and terminal workflows) that still hold one.
#
# Waiters are FIFO by landing start: a unit only takes a free lock when no
# other unit that started landing earlier is also waiting for it.
class MergeLock
  # Step kinds that merge into a landing branch (the job-bundle land path runs
  # as a merge-train land).
  # Publish steps that write straight to a branch take it too (NY41).
  STEP_KINDS = %w[auto_merge merge_train_land merge_train_land_after_rebase external_pr_merge
                  hotfix_sync_publish promotion_publish].freeze

  Lease = Struct.new(:lock, :key) do
    def release!
      lock&.release! if lock&.active?
    end
  end

  DETAIL_KEY = "merge_lock_key".freeze

  class << self
    # Returns a Lease when the lock was taken (or none is needed because the
    # workflow has no WorkUnit), or nil when it is held or an earlier waiter is
    # ahead. `key` is resolved once by the caller (resolving it reads the
    # delivery policy) and is recorded on the step so other waiters compare
    # keys without resolving anything.
    def try_acquire(workflow:, job:, step: nil, key: WorkDefinitions.merge_lock_key_for(job))
      unit = workflow.work_unit
      return Lease.new(nil, key) if key.nil? || unit.nil?

      register_waiter(step, key)
      existing = unit.work_unit_locks.active.find_by(lock_key: key)
      return Lease.new(existing, key) if existing
      return nil if WorkUnitLock.active.exists?(lock_key: key)
      return nil if earlier_waiter?(workflow, unit, key)

      Lease.new(unit.work_unit_locks.create!(lock_key: key), key)
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    private

    def register_waiter(step, key)
      return if step.nil? || step.inline_details[DETAIL_KEY] == key

      step.update_details_columns!(step.inline_details.merge(DETAIL_KEY => key))
    end

    # Another landing unit on the same branch that is also in a merge step,
    # and started landing before this one.
    def earlier_waiter?(workflow, unit, key)
      mine = order_key(unit)
      Step.where(kind: STEP_KINDS, state: "running").where.not(workflow_id: workflow.id)
        .includes(workflow: :work_unit).any? do |other|
          next false unless other.inline_details[DETAIL_KEY] == key

          other_unit = other.workflow.work_unit
          next false unless other_unit&.active?

          (order_key(other_unit) <=> mine) == -1
        end
    end

    def order_key(unit)
      [ (unit.started_at || unit.created_at).to_f, unit.id ]
    end
  end
end
