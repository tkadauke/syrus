module Steps
  # Holds the per-landing-branch MergeLock around a step's final merge
  # sequence. Release happens on every exit: success, deferral, failure.
  module MergeLockControl
    MERGE_LOCK_WAIT = 10.minutes
    MERGE_LOCK_POLL = 2.seconds

    class << self
      # Test seams: specs shorten the wait and poll so nothing sleeps.
      attr_writer :merge_lock_wait, :merge_lock_poll

      def merge_lock_wait = @merge_lock_wait || MERGE_LOCK_WAIT
      def merge_lock_poll = @merge_lock_poll || MERGE_LOCK_POLL
    end

    private

    # Yields once the merge lock is held. If it cannot be taken within the
    # wait budget, calls `on_timeout` (defer or fail) instead of yielding.
    def with_merge_lock(context:, on_timeout:)
      lease = acquire_merge_lock(context)
      return on_timeout.call unless lease

      begin
        yield
      ensure
        lease.release!
      end
    end

    def acquire_merge_lock(context)
      deadline = Time.current + MergeLockControl.merge_lock_wait
      logged = false
      key = WorkDefinitions.merge_lock_key_for(job)
      loop do
        lease = MergeLock.try_acquire(workflow: workflow, job: job, step: step, key: key)
        return lease if lease

        return nil if Time.current >= deadline

        unless logged
          log("#{context}: waiting for the merge lock held by another landing", kind: "system")
          logged = true
        end
        poll = MergeLockControl.merge_lock_poll.to_f
        sleep(poll) if poll.positive?
      end
    end
  end
end
