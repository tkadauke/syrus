# Restricted evidence for one finished build attempt: what the attempt was
# bound to (source, base images, policy snapshot, builder version), what it
# reached on the network, what it produced (layer digests), what it measured,
# and its sanitized bounded log. Written once, when the attempt reaches a
# terminal state. The log and destination detail are for administrators only;
# #safe_summary is the subset that may be emitted elsewhere.
class RuntimeImageBuildEvidence < ApplicationRecord
  OUTCOMES = %w[succeeded failed canceled].freeze
  JSON_COLUMNS = %i[base_images policy_snapshot destinations layer_digests resources].freeze

  belongs_to :request, class_name: "RuntimeImageBuildRequest", foreign_key: :runtime_image_build_request_id,
             inverse_of: :evidences
  belongs_to :attempt, class_name: "RuntimeImageBuildAttempt", foreign_key: :runtime_image_build_attempt_id,
             inverse_of: :evidence
  belongs_to :runtime_image, optional: true

  attribute :base_images, :json, default: -> { [] }
  attribute :policy_snapshot, :json, default: -> { [] }
  attribute :destinations, :json, default: -> { [] }
  attribute :layer_digests, :json, default: -> { [] }
  attribute :resources, :json, default: -> { {} }

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :source_digest, :finished_at, presence: true
  validates :runtime_image_build_attempt_id, uniqueness: true

  scope :retention_payload_candidates, -> { where.not(log: nil) }

  # No log text, no resolved addresses, no per-rule policy: counts, digests,
  # and measurements only.
  def safe_summary
    {
      "attempt" => attempt.number, "outcome" => outcome, "error_code" => error_code,
      "source_digest" => source_digest, "image_digest" => image_digest, "policy_digest" => policy_digest,
      "builder_version" => builder_version, "platform" => platform,
      "base_images" => Array(base_images).map { |base| base.slice("reference", "digest", "pinned") },
      "layer_count" => Array(layer_digests).size, "layer_digests" => Array(layer_digests),
      "destination_count" => Array(destinations).sum { |entry| entry["count"].to_i },
      "resources" => resources, "log_bytes" => log_bytes, "log_dropped_bytes" => log_dropped_bytes,
      "finished_at" => finished_at&.iso8601
    }.compact
  end
end
