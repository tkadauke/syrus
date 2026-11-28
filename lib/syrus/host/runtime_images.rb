module Syrus
  module Host
    # Plugin-facing entry to the Runtime Image Service for images a plugin
    # builds and needs every worker to be able to run.
    module RuntimeImages
      def self.available? = ::RuntimeImages::BuiltImages.new.available?

      def self.find(**) = ::RuntimeImages::BuiltImages.new.find(**)

      def self.publish_local(**) = ::RuntimeImages::BuiltImages.new.publish_local(**)

      def self.acquire(image, **options, &) = ::RuntimeImages::BuiltImages.new.acquire(image, **options, &)

      def self.active_base(**) = ::RuntimeImages::BuildRequests.new.active_base(**)

      def self.base_for_rebuild(id) = ::RuntimeImages::BuildRequests.new.base_for_rebuild(id)

      def self.base_launch(**) = ::RuntimeImages::BuildRequests.new.base_launch(**)

      def self.current_launch_contract?(image, **) = ::RuntimeImages::RuntimeAbi.current_contract?(image, **)

      def self.request_build(**) = ::RuntimeImages::BuildRequests.new.submit(**)

      # Returns the newest unexpired accepted attestation only when it covers
      # the complete effective verification policy in force for this build.
      def self.current_verification_attestation(image:, build_request:, now: Time.current)
        return unless image && build_request

        attempt = image.runtime_image_verification_attempts.order(number: :desc).first
        return unless attempt&.accepted? && attempt.image_digest == image.digest

        policy = ::RuntimeImages::Builds::Runner.new.verification_policy(
          build_request, base_policy: ::RuntimeImages::Verifications::Policy.current
        )
        digest = ::RuntimeImages::Verifications::CanonicalJson.digest(policy)
        return unless attempt.policy_digest == digest

        attempt.attestation if attempt.attestation&.valid_at?(now)
      end

      def self.retain(image, **) = ::RuntimeImages::Service.new.retain(image, **)

      def self.revoke(image, **) = ::RuntimeImages::Service.new.revoke(image, **)

      # Returns the sanitized reason and severity recorded by the authoritative
      # revocation operation for this exact image digest. The signal survives a
      # provider-side failure after the durable image was made unlaunchable.
      def self.revocation_details(image)
        ::RuntimeImageAuditEvent.where(runtime_image_id: image.id, event_type: "revoke")
          .recent_first.pick(:details) || {}
      end

      def self.delete(image, **) = ::RuntimeImages::Service.new.delete(image, **)

      def self.audit(event_type, **) = ::RuntimeImages::Audit.record(event_type, **)
    end
  end
end
