# The ordinary, coworker-safe environment inspection contract. Exact logs,
# network destinations, policy rules, and scanner output remain restricted to
# administrator evidence surfaces.
class Coworkers::EnvironmentInspectionSerializer
  SCHEMA_VERSION = 1
  SAFE_EVIDENCE_KEYS = %w[
    attempt outcome error_code source_digest image_digest policy_digest builder_version platform
    base_images layer_count layer_digests destination_count resources log_bytes log_dropped_bytes finished_at
  ].freeze

  def initialize(snapshot)
    @snapshot = snapshot
  end

  def as_json(*)
    {
      "v" => SCHEMA_VERSION,
      "environment_id" => environment.id,
      "state" => environment.state,
      "current_source_revision" => revision_identity(snapshot.source_revision),
      "build_status" => build_status(snapshot.build_revision),
      "candidate_revision" => revision_identity(snapshot.candidate_revision),
      "candidate_verification_summary" => safe_verification(snapshot.candidate_revision),
      "active_digest" => snapshot.active_revision&.runtime_image&.digest,
      "retained_rollback_digests" => snapshot.rollback_revisions.filter_map { |revision| rollback_summary(revision) },
      "compatibility" => compatibility(snapshot.candidate_revision || snapshot.active_revision),
      "error_code" => environment.last_error_code,
      "updated_at" => environment.updated_at&.iso8601
    }
  end

  private

  attr_reader :snapshot

  def environment = snapshot.environment

  def revision_identity(revision)
    return unless revision

    { "id" => revision.id, "number" => revision.number, "digest" => revision.source_digest,
      "state" => revision.state, "captured_at" => revision.created_at&.iso8601 }
  end

  def build_status(revision)
    request = revision&.build_request
    return unless request

    result = request.result
    { "request_id" => request.id, "state" => request.state, "attempts" => request.attempts_count,
      "error_code" => result&.error_code, "finished_at" => result&.finished_at&.iso8601 }.compact
  end

  def safe_verification(revision)
    return unless revision

    latest_attempt = revision.runtime_image&.runtime_image_verification_attempts&.max_by(&:number)
    attestation = latest_attempt&.attestation
    if attestation
      return attestation.safe_summary.merge(
        "issued_at" => attestation.issued_at.iso8601,
        "expires_at" => attestation.expires_at.iso8601,
        "valid" => attestation.valid_at?
      )
    end

    request = revision.build_request
    evidence = request&.evidences&.last
    return evidence.safe_summary if evidence

    request&.result&.details.to_h.fetch("evidence", {}).slice(*SAFE_EVIDENCE_KEYS).presence
  end

  def rollback_summary(revision)
    image = revision.runtime_image
    return unless image

    { "digest" => image.digest, "revision_id" => revision.id, "revision_number" => revision.number }
  end

  def compatibility(revision)
    base = snapshot.active_base
    status = if revision.nil?
      "not_applicable"
    elsif base.nil?
      "unknown"
    elsif revision.compatible_with?(base.runtime_abi)
      "compatible"
    else
      "incompatible"
    end

    { "status" => status, "current_runtime_abi" => base&.runtime_abi,
      "revision_runtime_abi" => revision&.runtime_abi,
      "minimum_runtime_abi" => revision&.compat_min, "maximum_runtime_abi" => revision&.compat_max }.compact
  end
end
