# In-process single-flight: when several threads in the same web/worker
# process ask for the same key at the same time, only the first actually runs
# the block. The rest block on it and share its result instead of repeating
# the underlying computation.
#
# This is intentionally per-process, not cluster-wide. The motivating
# incident (see CLAUDE.md/EPIC-392) was several browser tabs synchronizing on
# the same expensive Job/Workflow snapshot request; Puma's thread pool means
# those requests are realistically served by threads inside one process, so
# an in-process Mutex/ConditionVariable is enough to collapse them. A
# cross-process lock (like RepositoryCommitDistance's file lock for bare-clone
# refreshes) would add real complexity for a case this codebase does not
# currently need coalesced across processes.
#
#   result, coalesced = RequestCoalescer.call("job:42:workflows:page=1") { expensive_build }
#
# `coalesced` is true for every caller that waited on someone else's
# in-flight computation rather than running the block itself -- callers use
# it to label a "coalesced" outcome on their own metrics rather than
# double-counting a "computed" one.
class RequestCoalescer
  Entry = Struct.new(:mutex, :condition, :done, :result, :error)

  @registry_mutex = Mutex.new
  @entries = {}

  class << self
    def call(key)
      raise ArgumentError, "block required" unless block_given?

      entry, leader = claim(key)
      return follow(entry) unless leader

      begin
        result = yield
        entry.mutex.synchronize do
          entry.result = result
          entry.done = true
          entry.condition.broadcast
        end
        [ result, false ]
      rescue StandardError => e
        entry.mutex.synchronize do
          entry.error = e
          entry.done = true
          entry.condition.broadcast
        end
        raise
      ensure
        release(key, entry)
      end
    end

    # Test seam: clears in-flight bookkeeping between examples. Never call
    # from application code -- an entry mid-flight belongs to a real request.
    def reset!
      @registry_mutex.synchronize { @entries.clear }
    end

    private

    def claim(key)
      @registry_mutex.synchronize do
        entry = @entries[key]
        return [ entry, false ] if entry

        entry = Entry.new(Mutex.new, ConditionVariable.new, false, nil, nil)
        @entries[key] = entry
        [ entry, true ]
      end
    end

    def follow(entry)
      entry.mutex.synchronize do
        entry.condition.wait(entry.mutex) until entry.done
      end
      raise entry.error if entry.error

      [ entry.result, true ]
    end

    # Only the leader removes its own entry, and only if nobody has already
    # replaced it (defensive against a future change that reuses keys across
    # unrelated calls) -- a follower must never race the leader for cleanup.
    def release(key, entry)
      @registry_mutex.synchronize { @entries.delete(key) if @entries[key].equal?(entry) }
    end
  end
end
