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

      # Process attribution pins a content digest rather than a registry
      # namespace. Lock every matching record so revocation of that digest in
      # any namespace shares this admission boundary.
      images = RuntimeImage.where(digest: digest.to_s).order(:id).lock.to_a
      return if images.present? && images.all?(&:pullable?)

      raise NotPullable, "runtime image #{digest} was revoked before process launch"
    end

    def request_termination(digest, now: Time.current)
      # Registration happens before the OS process is spawned. Include
      # pidless registrations so a revocation that lands in that window marks
      # the turn for termination before or immediately after it starts.
      SpawnedProcess.running
        .where(kind: "agent")
        .where(kill_requested_at: nil)
        .where("json_extract(resource_attribution, '$.runtime_image_digest') = ?", digest.to_s)
        .update_all(kill_requested_at: now, updated_at: now)
    end
    private_class_method :request_termination
  end
end
