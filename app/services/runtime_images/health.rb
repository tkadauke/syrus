module RuntimeImages
  # Operator-facing health of the Runtime Image Service, derived from durable
  # records only (no registry round trip), so it is cheap enough for an admin
  # page or a scrape. Use RuntimeImages::OciRegistry::Diagnostics for a live
  # registry and credential probe.
  class Health
    Check = Data.define(:name, :status, :detail)

    WINDOW = 24.hours
    STUCK_PENDING_AFTER = 1.hour
    RETAINED_EXPIRING_SOON = 7.days

    def initialize(now: Time.current)
      @now = now
    end

    def checks
      [ provider_check, pending_check, cleanup_check, corruption_check, auth_check, storage_check, retention_check, base_check ] + builds.checks
    end

    def ok? = checks.none? { |check| check.status == :fail }

    # One JSON-friendly snapshot for the admin diagnostics endpoint.
    def snapshot
      {
        checks: checks.map(&:to_h),
        builds: builds.snapshot,
        images: RuntimeImage.group(:availability).count,
        retained: retained_summary,
        cleanup_failures: cleanup_failures,
        pulls: RuntimeImagePullEvent.since(@now - WINDOW).group(:outcome).count,
        pull_hit_ratio: RuntimeImagePullEvent.hit_ratio(RuntimeImagePullEvent.since(@now - WINDOW)),
        cache: cache_summary,
        coworker_base: base_snapshot,
        recent_audit: RuntimeImageAuditEvent.recent_first.limit(25).map do |event|
          { id: event.id, event_type: event.event_type, outcome: event.outcome, digest: event.digest,
            actor: event.actor, details: event.details, occurred_at: event.occurred_at }
        end
      }
    end

    def builds = @builds ||= Builds::Health.new(now: @now)

    def cleanup_failures
      RuntimeImage.cleanup_failed.order(cleanup_failed_at: :desc).limit(50).map do |image|
        { id: image.id, digest: image.digest, availability: image.availability, attempts: image.cleanup_failure_count,
          last_error: image.cleanup_last_error, failed_at: image.cleanup_failed_at,
          exhausted: image.cleanup_failure_count >= Collector::MAX_CLEANUP_ATTEMPTS }
      end
    end

    def retained_summary
      held = RuntimeImage.where(retention_state: "retained").where.not(availability: "deleted")
      {
        count: held.count,
        expiring_soon: held.where(retain_until: ..(@now + RETAINED_EXPIRING_SOON)).count,
        images: held.order(:retain_until).limit(50).map do |image|
          { id: image.id, digest: image.digest, retain_until: image.retain_until, reason: image.retention_reason,
            availability: image.availability }
        end
      }
    end

    def cache_summary
      entries = RuntimeImageCacheEntry.group(:hostname).pluck(:hostname, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(size_bytes), 0)"))
      entries.map { |host, count, bytes| { hostname: host, entries: count.to_i, bytes: bytes.to_i } }
    end

    # Promotion state of the standard coworker base: what is active and
    # rollback-able per platform, candidates awaiting promotion, revocations,
    # and the environments that now need a rebuild.
    def base_snapshot
      releases = CoworkerBaseRelease.includes(:runtime_image).newest_first.limit(100).to_a
      {
        platforms: CoworkerBase.platforms.map do |platform|
          state = BaseReleases.new.launch_state(platform: platform, now: @now)
          { platform: platform, state: state.state, message: state.message,
            active: state.release && base_release_json(state.release),
            rollback_targets: BaseReleases.new.rollback_targets(platform: platform, now: @now).map { |release| base_release_json(release) } }
        end,
        candidates: releases.select(&:candidate?).map { |release| base_release_json(release) },
        revoked: releases.select(&:revoked?).map { |release| base_release_json(release) },
        needing_rebuild: base_compatibility.summary
      }
    end

    def base_release_json(release)
      { id: release.id, digest: release.digest, platform: release.platform, generation: release.generation,
        runtime_abi: release.runtime_abi, compatibility: [ release.compat_min, release.compat_max ], status: release.status,
        promoted_at: release.promoted_at, promoted_by: release.promoted_by, retired_at: release.retired_at,
        supported_until: release.supported_until, revoked_at: release.revoked_at, revoked_by: release.revoked_by,
        revocation_severity: release.revocation_severity, revoked_reason: release.revoked_reason }
    end

    private

    def base_compatibility = @base_compatibility ||= BaseCompatibility.new(now: @now)

    # Launching is blocked (warn, not fail: a Syrus without coworker bases
    # configured is a valid install) when a base was ever published but none is
    # launchable, and failed when a promoted base was revoked or environments
    # are left without any base to rebuild against.
    def base_check
      return Check.new("coworker base", :ok, "no coworker base published") unless CoworkerBaseRelease.exists?

      blocked = CoworkerBaseRelease.distinct.pluck(:platform).sort.filter_map do |platform|
        state = BaseReleases.new.launch_state(platform: platform, now: @now)
        "#{platform}: #{state.state}" unless state.ready?
      end
      needing = base_compatibility.environments_needing_rebuild
      candidates = CoworkerBaseRelease.candidates.count
      if blocked.any? && CoworkerBaseRelease.where.not(promoted_at: nil).exists?
        return Check.new("coworker base", :fail, "new coworker turns are blocked (#{blocked.join(", ")}); promote a candidate or roll back")
      end
      return Check.new("coworker base", :warn, "#{needing.size} environment(s) need a rebuild against the active coworker base") if needing.any?
      return Check.new("coworker base", :warn, "#{candidates} base candidate(s) awaiting promotion, none active") if blocked.any?
      Check.new("coworker base", :ok, candidates.positive? ? "active; #{candidates} candidate(s) awaiting promotion" : "active")
    end

    def provider_check
      keys = RuntimeImageNamespace.distinct.pluck(:provider_key)
      missing = keys.reject { |key| Providers.keys.include?(key) }
      return Check.new("providers", :fail, "no provider registered for #{missing.join(', ')}") if missing.any?
      Check.new("providers", :ok, keys.empty? ? "no namespaces" : "#{keys.size} provider(s) registered")
    end

    def pending_check
      stuck = RuntimeImage.where(availability: "pending").where(created_at: ...(@now - STUCK_PENDING_AFTER)).count
      return Check.new("pending images", :ok, "none stuck") if stuck.zero?
      Check.new("pending images", :warn, "#{stuck} image(s) pending for over an hour; run runtime_images:reconcile")
    end

    def cleanup_check
      failing = RuntimeImage.cleanup_failed
      return Check.new("image cleanup", :ok, "no failed cleanup") unless failing.exists?
      exhausted = failing.where("cleanup_failure_count >= ?", Collector::MAX_CLEANUP_ATTEMPTS).count
      detail = "#{failing.count} image(s) failed cleanup, #{exhausted} out of retries"
      Check.new("image cleanup", exhausted.positive? ? :fail : :warn, detail)
    end

    def corruption_check
      count = recent_pulls.where(outcome: "corrupt").count
      return Check.new("image integrity", :ok, "no corrupt pulls in 24h") if count.zero?
      Check.new("image integrity", :fail, "#{count} corrupt pull(s) in 24h")
    end

    def auth_check
      count = RuntimeImageAuditEvent.since(@now - WINDOW).where(event_type: "auth", outcome: "failed").count
      return Check.new("registry authentication", :ok, "no failures in 24h") if count.zero?
      Check.new("registry authentication", :fail, "#{count} authentication failure(s) in 24h")
    end

    def storage_check
      unavailable = recent_pulls.where(outcome: %w[registry_unavailable timeout]).count
      hosts = WorkerHostHealthSample.where(observed_at: (@now - 15.minutes)..).where.not(data_root_used_percent: nil)
                                    .where("data_root_used_percent >= ?", WorkerCache::HIGH_PRESSURE_PERCENT).distinct.count(:hostname)
      return Check.new("storage", :ok, "no pressure, no registry timeouts") if unavailable.zero? && hosts.zero?
      Check.new("storage", :warn, "#{hosts} worker(s) at high disk pressure, #{unavailable} registry timeout/unavailable pull(s) in 24h")
    end

    def retention_check
      expiring = RuntimeImage.where(retention_state: "retained", retain_until: ..@now).where.not(availability: "deleted").count
      return Check.new("retention", :ok, "no lapsed holds") if expiring.zero?
      Check.new("retention", :warn, "#{expiring} lapsed hold(s) awaiting the next retention pass")
    end

    def recent_pulls = RuntimeImagePullEvent.since(@now - WINDOW)
  end
end
