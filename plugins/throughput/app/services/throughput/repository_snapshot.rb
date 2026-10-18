module Throughput
  class RepositorySnapshot
    FRESH_FOR = 10.minutes
    RETAIN_FOR = 24.hours
    REFRESH_LOCK_FOR = 10.minutes

    class Unavailable < StandardError; end

    def initialize(repository:, cache: Rails.cache, now: Time.current)
      @repository = repository
      @cache = cache
      @now = now
    end

    def read
      snapshot = cached_snapshot
      return decorate(snapshot, fresh?(snapshot) ? "fresh" : "stale") if snapshot

      computed = refresh!
      return decorate(computed, "computed") if computed

      snapshot = cached_snapshot
      return decorate(snapshot, fresh?(snapshot) ? "fresh" : "stale") if snapshot

      raise Unavailable, "repository throughput metrics are being prepared"
    end

    def refresh!
      existing = cached_snapshot
      return existing if existing && fresh?(existing)

      claimed = false
      claimed = cache.write(lock_key, true, unless_exist: true, expires_in: REFRESH_LOCK_FOR)
      return unless claimed

      payload = MetricContract.new(repository: repository, now: now).call
      cache.write(snapshot_key, payload, expires_in: RETAIN_FOR)
      payload
    ensure
      cache.delete(lock_key) if claimed
    end

    def self.snapshot_key(repository_id)
      "throughput:repository_snapshot:v#{MetricContract::VERSION}:repository:#{repository_id}"
    end

    private

    attr_reader :repository, :cache, :now

    def snapshot_key = self.class.snapshot_key(repository.id)
    def lock_key = "#{snapshot_key}:refreshing"
    def cached_snapshot = cache.read(snapshot_key)

    def fresh?(snapshot)
      generated_at = Time.iso8601(snapshot.fetch(:generated_at) { snapshot.fetch("generated_at") })
      generated_at >= now - FRESH_FOR
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def decorate(snapshot, status)
      snapshot.merge(cache_status: status)
    end
  end
end
