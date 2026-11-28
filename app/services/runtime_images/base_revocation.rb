module RuntimeImages
  # The signal turn runtimes use to decide whether a running turn must be
  # stopped because the coworker base it launched from was revoked.
  #
  # Only a severe revocation asks for termination; a standard revocation blocks
  # new launches (BaseReleases#launch_state) and lets running turns finish.
  # Callers ask by the digest the turn is pinned to, so the answer does not
  # depend on which release is currently active.
  module BaseRevocation
    Signal = Data.define(:digest, :severity, :reason, :revoked_at) do
      def terminate?
        severity == "severe" &&
          CoworkerEnvironmentPolicy.current.dig("revocation", "severe_running_turns") == "terminate"
      end
    end

    module_function

    # nil when the digest is not a revoked coworker base.
    def for_digest(digest)
      release = CoworkerBaseRelease.revoked.joins(:runtime_image).find_by(runtime_images: { digest: digest.to_s })
      release && signal_for(release)
    end

    def terminate?(digest) = !!for_digest(digest)&.terminate?

    # Every severely revoked base, newest first; +since+ narrows to revocations
    # a poller has not yet seen.
    def terminating(since: nil)
      return [] if CoworkerEnvironmentPolicy.current.dig("revocation", "severe_running_turns") != "terminate"

      scope = CoworkerBaseRelease.severely_revoked.includes(:runtime_image).order(revoked_at: :desc)
      scope = scope.where(revoked_at: since..) if since
      scope.map { |release| signal_for(release) }
    end

    def signal_for(release)
      Signal.new(digest: release.digest, severity: release.revocation_severity, reason: release.revoked_reason, revoked_at: release.revoked_at)
    end
  end
end
