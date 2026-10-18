require "securerandom"
require "timeout"

module Throughput
  class RepositorySnapshot
    FRESH_FOR = 10.minutes
    RETAIN_FOR = 24.hours
    COMPUTE_TIMEOUT = 4.minutes
    REFRESH_LOCK_FOR = 5.minutes

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
    rescue Timeout::Error
      raise Unavailable, "repository throughput metrics computation timed out"
    end

    def refresh!
      existing = cached_snapshot
      return existing if existing && fresh?(existing)

      claimed = cache.write(lock_key, SecureRandom.uuid, unless_exist: true, expires_in: REFRESH_LOCK_FOR)
      return unless claimed

      payload = Timeout.timeout(COMPUTE_TIMEOUT) do
        MetricContract.new(repository: repository, now: now).call
      end
      cache.write(snapshot_key, payload, expires_in: RETAIN_FOR)
      payload
    end

    def refresh_needed?
      snapshot = cached_snapshot
      snapshot.nil? || !fresh?(snapshot)
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
