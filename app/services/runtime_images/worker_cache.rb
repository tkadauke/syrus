require "socket"

module RuntimeImages
  # Worker-local cache of runtime images, keyed by immutable digest.
  #
  # Every image is pulled by digest and the engine must then prove it holds
  # that digest, otherwise the local copy is removed and the pull fails as
  # corrupt. Pull concurrency is bounded per process, concurrent requests for
  # one digest share a single pull, and eviction is LRU over entries that are
  # not leased. Image identity is deliberately not a worker capability: the
  # cache only records what a host holds and how pulls went.
  class WorkerCache
    DEFAULT_MAX_PULLS = 2
    DEFAULT_PULL_TIMEOUT = 600
    DEFAULT_ACQUIRE_TIMEOUT = 60
    DEFAULT_LEASE_SECONDS = 3600
    # An eviction claim older than this is treated as abandoned by a crashed
    # process (engine removal itself is bounded well below it).
    DEFAULT_CLAIM_TTL = 300
    HIGH_PRESSURE_PERCENT = 80.0
    CRITICAL_PRESSURE_PERCENT = 92.0

    Pulled = Data.define(:reference, :cache_hit, :entry)
    PrefetchResult = Data.define(:image, :outcome, :error)

    attr_reader :hostname

    def initialize(engine:, service: Service.new, hostname: Socket.gethostname, max_concurrent_pulls: DEFAULT_MAX_PULLS,
                   pull_timeout: DEFAULT_PULL_TIMEOUT, acquire_timeout: DEFAULT_ACQUIRE_TIMEOUT,
                   lease_seconds: DEFAULT_LEASE_SECONDS, claim_ttl: DEFAULT_CLAIM_TTL, clock: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
      @engine = engine
      @service = service
      @hostname = hostname
      @pull_timeout = pull_timeout
      @acquire_timeout = acquire_timeout
      @lease_seconds = lease_seconds
      @claim_ttl = claim_ttl
      # Takeover of a stale claim is only safe if the original owner's engine
      # removal cannot still be running, so the Engine#remove bound must be
      # shorter than the TTL.
      bound = @engine.respond_to?(:remove_timeout) ? @engine.remove_timeout : nil
      raise ArgumentError, "claim_ttl (#{claim_ttl}s) must exceed the engine remove timeout (#{bound}s)" if bound && claim_ttl <= bound
      @clock = clock
      @sleeper = sleeper
      @slots = Concurrent::Semaphore.new(Integer(max_concurrent_pulls))
      @inflight = {}
      @inflight_mutex = Mutex.new
    end

    # Makes the image available locally and leases it so eviction cannot
    # remove it while in use. Yields the pullable reference when a block is
    # given and releases the lease afterwards.
    #
    # Standard coworker base images are validated against the runtime ABI
    # before the lease is handed out (fail closed): an incompatible, unsigned,
    # or under-confined image raises RuntimeAbi::Incompatible and is never
    # returned to a launcher. +provider+ narrows the check to the provider
    # the turn will run; +confinement_policy+ is what the worker enforces.
    def acquire(image, prefetch: false, provider: nil, confinement_policy: RuntimeAbi::CONFINEMENT_POLICY_VERSION)
      unless image.reload.pullable?
        record(image, "revoked", monotonic, cache_hit: false, prefetch: prefetch)
        raise NotPullable, "runtime image #{image.digest} is #{image.availability}"
      end
      entry, hit = lease_local(image, prefetch)
      begin
        validate_abi!(image, provider: provider, confinement_policy: confinement_policy)
      rescue RuntimeAbi::Incompatible
        release(entry)
        raise
      end
      return Pulled.new(reference: reference_for(image), cache_hit: hit, entry: entry) unless block_given?
      begin
        yield reference_for(image)
      ensure
        release(entry)
      end
    end

    # Drops one lease. The entry stays protected until every concurrent
    # holder has released (or the lease expires). Non-block callers pass
    # Pulled#entry.
    #
    # Only a release of the lease epoch this holder joined counts down. A
    # holder that outlived its lease would otherwise release the lease a later
    # acquisition started over, and eviction could remove that holder's image
    # (formal/SyrusModel/CacheLease.lean, `current_holder_protected`).
    def release(entry)
      scope = RuntimeImageCacheEntry.where(id: entry.id, lease_epoch: entry.lease_epoch)
      scope.where("lease_count > 0").update_all("lease_count = lease_count - 1")
      scope.where(lease_count: 0).update_all(leased_until: nil)
      nil
    end

    # Warms the cache. Never raises, never evicts, and stands down when disk
    # pressure is already high so speculation cannot starve real work.
    def prefetch(images)
      Array(images).map do |image|
        next PrefetchResult.new(image: image, outcome: "skipped_pressure", error: nil) if pressure[:level] != "ok"
        next PrefetchResult.new(image: image, outcome: "skipped_not_pullable", error: nil) unless image.reload.pullable?
        begin
          ensure_local(image, prefetch: true)
          PrefetchResult.new(image: image, outcome: "ready", error: nil)
        rescue Error => e
          PrefetchResult.new(image: image, outcome: "failed", error: e)
        end
      end
    end

    def inventory
      RuntimeImageCacheEntry.for_host(hostname).includes(:runtime_image).lru.map do |entry|
        { digest: entry.digest, state: entry.state, size_bytes: entry.size_bytes, prefetched: entry.prefetched,
          last_used_at: entry.last_used_at, leased: entry.leased?(@clock.call), availability: entry.runtime_image.availability }
      end
    end

    def pressure
      usage = @engine.disk_usage
      total = usage.fetch(:total_bytes).to_f
      free = usage.fetch(:free_bytes).to_f
      used_percent = total.zero? ? 0.0 : ((total - free) / total * 100).round(1)
      level = if used_percent >= CRITICAL_PRESSURE_PERCENT then "critical"
      elsif used_percent >= HIGH_PRESSURE_PERCENT then "high"
      else "ok"
      end
      { total_bytes: total.to_i, free_bytes: free.to_i, used_percent: used_percent, level: level,
        cache_bytes: RuntimeImageCacheEntry.for_host(hostname).sum(:size_bytes) }
    end

    # Removes least-recently-used unleased entries until the cache is at or
    # below target_bytes. Revoked or deleted images go first regardless of age.
    # Leased entries are never touched. Returns the evicted digests.
    def evict(target_bytes:)
      evicted = []
      candidates = RuntimeImageCacheEntry.for_host(hostname).unleased(@clock.call).includes(:runtime_image).lru.to_a
      candidates.sort_by! { |entry| entry.runtime_image.pullable? ? 1 : 0 }
      total = cache_bytes
      candidates.each do |entry|
        break if total <= target_bytes && entry.runtime_image.pullable?
        next unless remove_entry(entry)
        evicted << entry.digest
        total -= entry.size_bytes.to_i
      end
      evicted
    end

    # Brings the cache back under pressure by evicting to a percentage of the
    # current cache size. A no-op while pressure is ok.
    def relieve_pressure!(fraction: 0.5)
      return [] if pressure[:level] == "ok"
      evict(target_bytes: (cache_bytes * fraction).to_i)
    end

    # Drops local copies of revoked/deleted digests that no workload holds.
    def purge_revoked
      entries = RuntimeImageCacheEntry.for_host(hostname).unleased(@clock.call).includes(:runtime_image).to_a
      entries.reject { |entry| entry.runtime_image.pullable? }.filter_map { |entry| entry.digest if remove_entry(entry) }
    end

    private

    def validate_abi!(image, provider:, confinement_policy:)
      return unless image.source_kind == CoworkerBase::SOURCE_KIND
      RuntimeAbi.validate_for_launch!(image: image, labels: @engine.labels(reference_for(image)), provider: provider, confinement_policy: confinement_policy)
    end

    def cache_bytes = RuntimeImageCacheEntry.for_host(hostname).sum(:size_bytes)

    def ensure_local(image, prefetch:)
      started = monotonic
      entry = settled_entry(image)
      if entry&.state == "present" && verified?(image)
        touch(entry) unless prefetch
        record(image, "hit", started, cache_hit: true, prefetch: prefetch)
        return [entry, true]
      end
      [single_flight(image, prefetch) { pull_and_verify(image, started, prefetch) }, false]
    end

    # An "evicting" row means eviction owns the engine removal. Pulling into
    # or promoting it would race that removal, so wait for the claim to
    # resolve: it either returns to "present" (removal failed) or the row is
    # deleted (removal done, safe to pull again).
    def settled_entry(image)
      deadline = monotonic + @acquire_timeout
      loop do
        entry = RuntimeImageCacheEntry.for_host(hostname).find_by(runtime_image: image)
        return entry unless entry&.state == "evicting"
        next if reconcile_abandoned_claim(entry)
        raise Busy, "runtime image #{image.digest} is being evicted on #{hostname}" if monotonic >= deadline
        @sleeper.call(EVICTION_POLL_SECONDS)
      end
    end

    # Takes over an eviction claim whose owner never resolved it (crashed
    # process). The takeover is a compare-and-set on the claim timestamp so
    # only one reconciler finishes the removal; a failed removal restores the
    # row, and a missing engine image simply fails verification and re-pulls.
    def reconcile_abandoned_claim(entry)
      now = @clock.call
      return false if entry.updated_at > now - @claim_ttl
      token = SecureRandom.hex(8)
      taken = RuntimeImageCacheEntry.where(id: entry.id, state: "evicting", claim_token: entry.claim_token).update_all(claim_token: token, updated_at: now)
      return false unless taken == 1
      finish_claim(entry, token)
      true
    end

    # Resolves a claim this process owns (identified by its token). Every
    # write is scoped to the token, so an owner whose claim was taken over
    # while its removal was running cannot roll back or delete the row.
    def finish_claim(entry, token)
      begin
        @engine.remove(entry.runtime_image.locator.to_s)
      rescue EngineError
        RuntimeImageCacheEntry.where(id: entry.id, state: "evicting", claim_token: token).update_all(state: "present", claim_token: nil)
        return false
      end
      RuntimeImageCacheEntry.where(id: entry.id, state: "evicting", claim_token: token).delete_all == 1
    end

    def pull_and_verify(image, started, prefetch)
      # Re-check durable state: the image may have been revoked while waiting.
      raise Revoked, "runtime image #{image.digest} was revoked" unless image.reload.pullable?
      with_slot(image, started, prefetch) do
        auth = grant_for(image)
        # Provider.pull verifies the manifest hashes to the digest and the
        # locator belongs to the namespace before any bytes move.
        @service.pull(image)
        @engine.pull(reference_for(image), timeout: @pull_timeout, auth: auth)
        unless @engine.digests(reference_for(image)).include?(image.digest)
          @engine.remove(reference_for(image)) rescue nil
          drop_entry(image)
          raise CorruptImage, "pulled content for #{image.digest} does not match the requested digest"
        end
        entry = upsert_entry(image, prefetch)
        record(image, "pulled", started, cache_hit: false, prefetch: prefetch)
        entry
      end
    rescue Error => e
      record_failure(image, e, started, prefetch)
      raise
    end

    def with_slot(image, started, prefetch)
      unless @slots.try_acquire(1, @acquire_timeout)
        raise Busy, "too many concurrent image pulls on #{hostname}"
      end
      begin
        yield
      ensure
        @slots.release
      end
    end

    # One pull per digest at a time; waiters reuse the result and then
    # re-verify through the normal hit path.
    def single_flight(image, prefetch)
      key = image.id
      owner, gate = @inflight_mutex.synchronize do
        existing = @inflight[key]
        existing ? [false, existing] : [true, (@inflight[key] = Mutex.new.tap(&:lock))]
      end
      if owner
        begin
          yield
        ensure
          @inflight_mutex.synchronize { @inflight.delete(key) }
          gate.unlock
        end
      else
        gate.synchronize { nil }
        entry = RuntimeImageCacheEntry.for_host(hostname).present.find_by(runtime_image: image)
        entry || single_flight(image, prefetch) { pull_and_verify(image, monotonic, prefetch) }
      end
    end

    def verified?(image)
      return true if @engine.digests(reference_for(image)).include?(image.digest)
      drop_entry(image)
      false
    end

    def reference_for(image) = image.locator.to_s

    def grant_for(image)
      provider = Providers.fetch(image.runtime_image_namespace.provider_key)
      provider.respond_to?(:worker_pull_grant) ? provider.worker_pull_grant(image.runtime_image_namespace) : nil
    rescue Unsupported, NotFound
      nil
    end

    def upsert_entry(image, prefetch)
      now = @clock.call
      entry = RuntimeImageCacheEntry.for_host(hostname).find_or_initialize_by(runtime_image: image)
      entry.assign_attributes(digest: image.digest, state: "present", size_bytes: @engine.size_bytes(reference_for(image)),
                              pulled_at: now, prefetched: prefetch, last_used_at: (prefetch ? entry.last_used_at : now))
      entry.save!
      entry
    end

    def drop_entry(image)
      RuntimeImageCacheEntry.for_host(hostname).where(runtime_image: image).delete_all
    end

    def touch(entry) = entry.update!(last_used_at: @clock.call, prefetched: false)

    # Counted per acquisition so overlapping users do not release each
    # other's protection; an expired lease starts over so crashed holders
    # cannot pin an entry forever.
    #
    # The lease is one conditional UPDATE that only matches a "present"
    # entry, and eviction claims an entry with one conditional UPDATE that
    # only matches an unleased "present" entry. The database serializes the
    # two, so exactly one wins: an acquired image is never removed, and an
    # evicted one is never reported as leased.
    #
    # Starting an expired lease over begins a new epoch; the holder records the
    # epoch it joined, which scopes its release. The epoch is read after the
    # update: it can only change again once this lease expires.
    def lease(entry)
      now = @clock.call
      leased = RuntimeImageCacheEntry.where(id: entry.id, state: "present").update_all([
        "lease_epoch = CASE WHEN leased_until IS NULL OR leased_until <= ? THEN lease_epoch + 1 ELSE lease_epoch END, " \
        "lease_count = CASE WHEN leased_until IS NULL OR leased_until <= ? THEN 1 ELSE lease_count + 1 END, leased_until = ?",
        now, now, now + @lease_seconds
      ]) == 1
      return false unless leased

      entry.lease_epoch = RuntimeImageCacheEntry.where(id: entry.id).pick(:lease_epoch)
      entry.clear_attribute_changes([ :lease_epoch ])
      true
    end

    # Ensures the image is local and leased. If eviction claimed the entry
    # between ensure_local and the lease, the image is pulled again.
    LEASE_ATTEMPTS = 3
    EVICTION_POLL_SECONDS = 0.05

    def lease_local(image, prefetch)
      LEASE_ATTEMPTS.times do
        entry, hit = ensure_local(image, prefetch: prefetch)
        return [entry, hit] if lease(entry)
      end
      raise Busy, "runtime image #{image.digest} kept being evicted on #{hostname}"
    end

    def remove_entry(entry)
      token = SecureRandom.hex(8)
      claimed = RuntimeImageCacheEntry.where(id: entry.id, state: "present").unleased(@clock.call).update_all(state: "evicting", claim_token: token, updated_at: @clock.call)
      return false unless claimed == 1
      finish_claim(entry, token)
    end

    def record_failure(image, error, started, prefetch)
      outcome = case error
      when Revoked, NotPullable then "revoked"
      when CorruptImage then "corrupt"
      when EngineTimeout then "timeout"
      when NotFound then "not_found"
      when Busy then "busy"
      when ProviderError, EngineError then "registry_unavailable"
      else "failed"
      end
      record(image, outcome, started, cache_hit: false, prefetch: prefetch, error: error)
    end

    def record(image, outcome, started, cache_hit:, prefetch:, error: nil)
      RuntimeImagePullEvent.create!(
        hostname: hostname, runtime_image: image, digest: image.digest, outcome: outcome, cache_hit: cache_hit,
        prefetch: prefetch, duration_ms: ((monotonic - started) * 1000).to_i,
        error_class: error&.class&.name, error_message: error&.message.to_s.truncate(500).presence
      )
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
