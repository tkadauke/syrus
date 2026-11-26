class RuntimeImageScanEvidence < ApplicationRecord
  belongs_to :attempt, class_name: "RuntimeImageVerificationAttempt",
             foreign_key: :runtime_image_verification_attempt_id, inverse_of: :scan_evidence
  has_one_attached :sbom
  has_one_attached :scan_report

  attr_readonly :runtime_image_verification_attempt_id, :image_digest, :scanner_name, :scanner_version,
                :database_version, :sbom_format, :sbom_digest, :report_digest, :finding_summary,
                :exemptions, :decision_evidence, :scanned_at
  attribute :finding_summary, :json, default: -> { {} }
  attribute :exemptions, :json, default: -> { [] }
  attribute :decision_evidence, :json, default: -> { {} }

  validates :runtime_image_verification_attempt_id, uniqueness: true
  validates :image_digest, :sbom_digest, :report_digest, format: { with: RuntimeImage::DIGEST_FORMAT }
  validates :scanner_name, :scanner_version, :database_version, :sbom_format, :scanned_at, presence: true
  validate :digest_matches_attempt

  private

  def digest_matches_attempt
    errors.add(:image_digest, :runtime_image_digest_mismatch) if attempt && image_digest != attempt.image_digest
  end
end
