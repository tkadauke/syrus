module RuntimeImages
  # Promotion lifecycle of the standard coworker base: which published base
  # digest new coworker turns launch from, which prior digests stay available
  # for rollback, and the emergency path that withdraws a digest.
  #
  #   candidate --promote--> active --(newer promote)--> retired --rollback--> active
  #   any state --revoke--> revoked   (terminal; the image is revoked too)
  #
  # At most one release is active per platform (a unique database key). Every
  # transition is audited. Nothing here falls back to another image: when no
  # release is launchable, +launch_state+ says why and callers block the turn.
  class BaseReleases
    # How long a retired base stays pullable so rollback remains possible.
    ROLLBACK_RETENTION = 90.days

    Problem = Data.define(:code, :message)

    class Refused < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = Array(problems)
        super(@problems.map(&:message).join("; "))
      end

      def codes = problems.map(&:code)
    end

    # +state+ is :ready, :no_active_base, or :base_revoked; +code+ is the
    # stable machine-readable form callers put in a blocked-turn error.
    LaunchState = Data.define(:state, :release, :message) do
      def ready? = state == :ready
      def code = ready? ? nil : state.to_s
    end

    def initialize(service: Service.new)
      @service = service
    end

    def active(platform: BuiltImages::DEFAULT_PLATFORM)
      CoworkerBaseRelease.active.for_platform(platform).first
    end

    # The image new turns launch from, or nil when launching is blocked.
    def current_image(platform: BuiltImages::DEFAULT_PLATFORM)
      launch_state(platform: platform).release&.runtime_image
    end

    def launch_state(platform: BuiltImages::DEFAULT_PLATFORM, now: Time.current)
      release = active(platform: platform)
      if release.nil?
        last = CoworkerBaseRelease.for_platform(platform).where.not(promoted_at: nil).order(promoted_at: :desc, id: :desc).first
        if last&.revoked?
          return LaunchState.new(:base_revoked, nil, "the coworker base #{last.digest} was revoked (#{last.revoked_reason}); promote a candidate or roll back")
        end
        return LaunchState.new(:no_active_base, nil, "no coworker base has been promoted for #{platform}")
      end
      problems = launch_problems(release, now: now)
      return LaunchState.new(:ready, release, nil) if problems.empty?
      LaunchState.new(:base_revoked, nil, problems.map(&:message).join("; "))
    end

    # Records a freshly published, conformance-verified base as a candidate.
    # Idempotent per image. A base without a valid signed ABI attestation is
    # never registered, so it can never be promoted.
    def register(image)
      existing = CoworkerBaseRelease.find_by(runtime_image_id: image.id)
      return existing if existing

      payload = signed_payload(image)
      unless image.source_kind == CoworkerBase::SOURCE_KIND && image.available? && payload
        Audit.record("base_release.register", outcome: :failed, image: image, details: { reason: "not a pullable base with a valid signed ABI attestation" })
        return nil
      end
      release = CoworkerBaseRelease.create!(
        runtime_image: image, platform: image.platform, generation: payload.fetch("generation"), runtime_abi: payload.fetch("version"),
        compat_min: payload.fetch("compat_min"), compat_max: payload.fetch("compat_max")
      )
      Audit.record("base_release.register", outcome: :ok, image: image, details: { generation: release.generation, runtime_abi: release.runtime_abi })
      release
    rescue ActiveRecord::RecordNotUnique
      CoworkerBaseRelease.find_by!(runtime_image_id: image.id)
    end

    # Makes a candidate the active base for its platform, retiring (but keeping
    # retained for rollback) the one it replaces.
    def promote!(release, actor:)
      raise Refused, [ not_a_candidate(release) ] unless release.candidate?
      activate!(release, actor: actor, event: "base_release.promote", from: "candidate")
    end

    # Re-activates a retired base: +to+, or the most recently retired launchable
    # base for the platform. The current active base becomes retired.
    def rollback!(platform: BuiltImages::DEFAULT_PLATFORM, to: nil, actor:)
      target = to || rollback_targets(platform: platform).first
      raise Refused, [ Problem.new("no_rollback_target", "no retired base is available to roll back to for #{platform}") ] unless target
      raise Refused, [ Problem.new("platform_mismatch", "release is for #{target.platform}, not #{platform}") ] unless target.platform == platform
      raise Refused, [ not_retired(target) ] unless target.retired?
      activate!(target, actor: actor, event: "base_release.rollback", from: "retired")
    end

    # Retired bases that could still be rolled back to, most recent first.
    def rollback_targets(platform: BuiltImages::DEFAULT_PLATFORM, now: Time.current)
      CoworkerBaseRelease.retired.for_platform(platform).order(retired_at: :desc, id: :desc).includes(:runtime_image)
                         .select { |release| launch_problems(release, now: now).empty? }
    end

    # Ends support for environments built on +release+ at +until_time+ (nil
    # clears the deadline). New launches of the base itself are unaffected;
    # environments still on it start being reported as needing a rebuild.
    def set_support_deadline!(release, until_time:, actor:)
      raise Refused, [ Problem.new("revoked", "a revoked base has no support window") ] if release.revoked?
      release.update!(supported_until: until_time)
      Audit.record("base_release.support", outcome: :ok, image: release.runtime_image, actor: actor,
                   details: { supported_until: until_time&.iso8601 })
      BaseRebuildDiscoveryJob.perform_later
      release
    end

    # Emergency withdrawal. The release and its image are revoked (no new
    # launch can use it, and the registry is told); a severe revocation also
    # becomes a termination signal for running turns (see BaseRevocation).
    # Revoking the active base leaves the platform blocked until another
    # candidate is promoted or a retired base is rolled back to.
    def revoke!(release, reason:, actor:, severity: "standard")
      raise ArgumentError, "severity must be one of #{CoworkerBaseRelease::SEVERITIES.join(", ")}" unless CoworkerBaseRelease::SEVERITIES.include?(severity.to_s)
      raise Refused, [ Problem.new("already_revoked", "release is already revoked") ] if release.revoked?
      reason = reason.to_s.strip
      raise Refused, [ Problem.new("reason_required", "a revocation reason is required") ] if reason.empty?

      image = release.runtime_image
      was_active = release.active?
      # Withdraw the image first: if the registry call fails nothing is half
      # revoked, and the operator can retry.
      @service.revoke(image, reason: reason, actor: actor, severity: severity) if image.available?
      mark_revoked!(release, reason: reason, actor: actor, severity: severity.to_s)
      image.release_retention! if image.retention_state == "retained"
      Audit.record("base_release.revoke", outcome: :ok, image: image, actor: actor,
                   details: { severity: severity, reason: reason, was_active: was_active })
      BaseRebuildDiscoveryJob.perform_later
      release
    end

    # Brings releases in line with their images when something other than this
    # service revoked or deleted the image (a failed conformance probe, a
    # reconciliation repair). Returns the releases it revoked.
    def sync_with_images!
      CoworkerBaseRelease.where.not(status: "revoked").includes(:runtime_image).filter_map do |release|
        image = release.runtime_image
        next unless image.revoked? || image.deleted?
        mark_revoked!(release, reason: image.revoked_reason.presence || "image #{image.availability}", actor: "system", severity: "standard")
        Audit.record("base_release.sync", outcome: :repaired, image: image, details: { reason: "image was #{image.availability} outside the release lifecycle" })
        release
      end
    end

    # Why +release+ cannot launch new turns right now (empty = launchable).
    def launch_problems(release, now: Time.current)
      image = release.runtime_image
      problems = []
      if release.revoked? || image.revoked?
        problems << Problem.new("base_revoked", "base #{image.digest} is revoked")
      elsif !image.pullable?
        problems << Problem.new("image_not_pullable", "base image #{image.digest} is #{image.availability}")
      end
      problems << Problem.new("abi_unsupported", "base ABI #{release.runtime_abi} is outside the range this Syrus launches (#{RuntimeAbi.compatibility.fetch("min")}..#{RuntimeAbi.compatibility.fetch("max")})") unless RuntimeAbi.supported?(release.runtime_abi)
      problems << Problem.new("abi_range_excludes_syrus", "base supports ABI #{release.compat_min}..#{release.compat_max}, this Syrus speaks #{RuntimeAbi.version}") unless release.compatibility_range.cover?(RuntimeAbi.version)
      problems << Problem.new("provenance_unsigned", "base provenance has no valid runtime ABI signature") unless signed_payload(image)
      problems
    end

    private

    # +from+ is the status the release must still have once the platform's
    # releases are locked: the checks above ran without the lock, and a
    # revoke! landing in between must not be overwritten (F138).
    def activate!(release, actor:, event:, from:)
      problems = launch_problems(release)
      raise Refused, problems if problems.any?

      previous = active(platform: release.platform)
      # Hold the replaced base for rollback before switching, so a registry
      # failure aborts the change instead of leaving no way back.
      @service.retain(previous.runtime_image, reason: "coworker base rollback window", until_time: Time.current + ROLLBACK_RETENTION, actor: actor) if previous
      @service.retain(release.runtime_image, reason: "active coworker base", actor: actor)

      now = Time.current
      CoworkerBaseRelease.transaction do
        CoworkerBaseRelease.for_platform(release.platform).lock.to_a
        release.reload(lock: true)
        raise Refused, [ from == "candidate" ? not_a_candidate(release) : not_retired(release) ] unless release.status == from
        locked_problems = launch_problems(release)
        raise Refused, locked_problems if locked_problems.any?
        # The base retained for rollback above is the one read before the
        # lock; if another promotion switched it meanwhile, retiring the new
        # one would skip its rollback retention, so let the operator retry.
        current = active(platform: release.platform)
        unless current&.id == previous&.id
          raise Refused, [ Problem.new("concurrent_change", "the active base for #{release.platform} changed while this was being applied; retry") ]
        end
        previous&.reload(lock: true)
        if previous&.active?
          previous.update!(status: "retired", active_key: nil, retired_at: now, retired_by: actor.to_s)
        end
        release.update!(status: "active", active_key: release.platform, promoted_at: now, promoted_by: actor.to_s, retired_at: nil, retired_by: nil)
      end
      Audit.record(event, outcome: :ok, image: release.runtime_image, actor: actor,
                   details: { platform: release.platform, generation: release.generation, runtime_abi: release.runtime_abi,
                              replaced: previous&.digest })
      BaseRebuildDiscoveryJob.perform_later
      release
    end

    def not_a_candidate(release)
      Problem.new("not_a_candidate", "release is #{release.status}; only a candidate can be promoted (use rollback for a retired base)")
    end

    def not_retired(release)
      Problem.new("not_retired", "release is #{release.status}; only a retired base can be rolled back to")
    end

    def mark_revoked!(release, reason:, actor:, severity:)
      release.update!(status: "revoked", active_key: nil, revoked_at: Time.current, revoked_by: actor.to_s,
                      revocation_severity: severity, revoked_reason: reason.to_s.truncate(500))
    end

    def signed_payload(image)
      attestation = Hash(image.provenance)[RuntimeAbi::ATTESTATION_KEY]
      return unless RuntimeAbi.attestation_valid?(attestation, source_digest: image.source_digest, recipe_digest: Hash(image.provenance)["recipe_digest"])
      payload = attestation.fetch("payload")
      payload if %w[generation version compat_min compat_max].all? { |key| payload[key].is_a?(Integer) }
    end
  end
end
