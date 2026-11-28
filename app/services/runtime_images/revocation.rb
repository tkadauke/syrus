module RuntimeImages
  module Revocation
    module_function

    def revoke_and_request_termination!(image, reason:, severity:, now: Time.current)
      count = 0
      image.with_lock do
        image.mark_revoked!(reason: reason, now: now)
        count = request_termination(image.digest, now:) if severity.to_s == "severe"
      end
      count
    end

    def assert_launchable!(digest)
      return if digest.blank?

      image = RuntimeImage.lock.find_by(digest: digest.to_s)
      return if image&.pullable?

      raise NotPullable, "runtime image #{digest} was revoked before process launch"
    end

    def request_termination(digest, now: Time.current)
      SpawnedProcess.live_agent
        .where(kill_requested_at: nil)
        .where("json_extract(resource_attribution, '$.runtime_image_digest') = ?", digest.to_s)
        .update_all(kill_requested_at: now, updated_at: now)
    end
    private_class_method :request_termination
  end
end
