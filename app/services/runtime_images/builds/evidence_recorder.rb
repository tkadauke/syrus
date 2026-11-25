module RuntimeImages
  module Builds
    # Persists an attempt's Evidence once the attempt is terminal. Recording is
    # observational: a failure here is logged and never changes the outcome of
    # the build it describes.
    class EvidenceRecorder
      def record(request:, attempt:, evidence:, now: Time.current)
        request = RuntimeImageBuildRequest.find(request.id)
        attempt = RuntimeImageBuildAttempt.find(attempt.id)
        return nil if attempt.active? || attempt.evidence || !RuntimeImageBuildEvidence::OUTCOMES.include?(attempt.state)

        result = request.result
        image = result&.runtime_image if attempt.state == "succeeded"
        record = RuntimeImageBuildEvidence.create!(
          request: request, attempt: attempt, runtime_image: image, outcome: attempt.state,
          error_code: attempt.error_code.presence || result&.error_code, source_digest: request.source_digest,
          recipe_digest: request.recipe_digest, platform: request.platform, image_digest: image&.digest || evidence.image_digest,
          policy_digest: evidence.policy_digest, builder_version: evidence.builder_version, base_images: evidence.base_images,
          policy_snapshot: evidence.policy_snapshot, destinations: evidence.destinations, layer_digests: evidence.layer_digests,
          resources: evidence.resources, log: evidence.finalize_log, log_bytes: evidence.log.bytes,
          log_dropped_bytes: evidence.log.dropped_bytes, finished_at: attempt.finished_at || now
        )
        summary = record.safe_summary
        result.update!(details: result.details.merge("evidence" => summary)) if result && !result.details.key?("evidence")
        Audit.record("build.evidence", outcome: "ok", image: image, namespace: request.runtime_image_namespace,
                                       actor: request.requester_kind, digest: record.image_digest,
                                       details: { "request_id" => request.id, "attempt" => attempt.number, "outcome" => record.outcome,
                                                  "policy_digest" => record.policy_digest, "layers" => record.layer_digests.size,
                                                  "log_bytes" => record.log_bytes })
        record
      rescue StandardError => e
        Rails.logger.warn("[RuntimeImages::Builds::EvidenceRecorder] could not record evidence: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
