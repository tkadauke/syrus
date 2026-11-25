module RuntimeImages
  # Finds environment images (anything published through the Runtime Image
  # Service that was built FROM a tracked coworker base, as recorded in the
  # image's build provenance) that can no longer be relied on after a base
  # change, so a rebuild against the active base can be requested.
  #
  # A superseded base is not a reason by itself: existing compatible
  # environments keep running. Only a revoked base, an ended support window, or
  # an ABI outside what this Syrus launches makes an environment need a rebuild.
  class BaseCompatibility
    Finding = Data.define(:image, :base, :reasons, :replacement) do
      def to_h
        { image_id: image.id, digest: image.digest, source_kind: image.source_kind, source_ref: image.source_ref,
          base_digest: base.digest, base_status: base.status, reasons: reasons,
          replacement_digest: replacement&.digest, blocked: replacement.nil? }
      end
    end

    def initialize(now: Time.current, batch_size: 500)
      @now = now
      @batch_size = batch_size
    end

    def reasons_for(release)
      reasons = []
      reasons << (release.severe? ? "base_revoked_severe" : "base_revoked") if release.revoked?
      reasons << "support_ended" if !release.revoked? && release.supported_until && release.supported_until <= @now
      reasons << "abi_unsupported" if !RuntimeAbi.supported?(release.runtime_abi) || !release.compatibility_range.cover?(RuntimeAbi.version)
      reasons
    end

    # Environments needing a rebuild, one finding per image. +replacement+ is
    # the active base to rebuild against (nil = none is launchable, so the
    # environment is blocked until one is promoted).
    def environments_needing_rebuild
      releases = CoworkerBaseRelease.includes(:runtime_image).index_by { |release| release.digest }
      return [] if releases.empty?

      stale = releases.select { |_, release| reasons_for(release).any? }
      return [] if stale.empty?

      replacements = {}
      findings = []
      RuntimeImage.pullable.where.not(source_kind: CoworkerBase::SOURCE_KIND).find_each(batch_size: @batch_size) do |image|
        digests = Array(Hash(image.provenance)["base_images"]).filter_map { |entry| entry["digest"] if entry.is_a?(Hash) }
        base = digests.filter_map { |digest| stale[digest] }.first
        next unless base

        replacement = replacements.fetch(base.platform) { replacements[base.platform] = BaseReleases.new.launch_state(platform: base.platform, now: @now).release }
        findings << Finding.new(image: image, base: base, reasons: reasons_for(base), replacement: replacement)
      end
      findings
    end

    def summary
      findings = environments_needing_rebuild
      { total: findings.size, blocked: findings.count { |f| f.replacement.nil? },
        by_reason: findings.flat_map(&:reasons).tally, environments: findings.first(50).map(&:to_h) }
    end
  end
end
