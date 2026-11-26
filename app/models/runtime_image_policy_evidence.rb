# Restricted remediation evidence for image-policy verification. Normal views
# use only safe_summary; the attached report may contain secret locations and
# is exposed only through administrator evidence authorization.
class RuntimeImagePolicyEvidence < ApplicationRecord
  belongs_to :attempt, class_name: "RuntimeImageVerificationAttempt",
             foreign_key: :runtime_image_verification_attempt_id, inverse_of: :policy_evidence
  has_one_attached :report

  attr_readonly :runtime_image_verification_attempt_id, :image_digest, :safe_summary, :report_digest, :scanned_at
  attribute :safe_summary, :json, default: -> { {} }

  validates :runtime_image_verification_attempt_id, uniqueness: true
  validates :image_digest, :report_digest, format: { with: RuntimeImage::DIGEST_FORMAT }
  validates :scanned_at, presence: true
  validate :digest_matches_attempt

  private

  def digest_matches_attempt
    errors.add(:image_digest, :runtime_image_digest_mismatch) if attempt && image_digest != attempt.image_digest
  end
end
