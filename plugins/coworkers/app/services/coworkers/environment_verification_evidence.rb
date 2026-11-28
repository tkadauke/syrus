module Coworkers
  # Resolves only an unexpired attestation for the image's newest attempt under
  # the complete policy that would be applied to this build today.
  class EnvironmentVerificationEvidence
    def self.current(revision, now: Time.current) = new(revision, now:).current

    def initialize(revision, now: Time.current)
      @revision = revision
      @now = now
    end

    def current
      Syrus::Host::RuntimeImages.current_verification_attestation(
        image: revision.runtime_image, build_request: revision.build_request, now:
      )
    end

    private

    attr_reader :revision, :now
  end
end
