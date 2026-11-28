class RuntimeImageVerificationAttestation < ApplicationRecord
  OUTCOMES = %w[accepted rejected blocked].freeze
  belongs_to :runtime_image
  belongs_to :attempt, class_name: "RuntimeImageVerificationAttempt", foreign_key: :runtime_image_verification_attempt_id, inverse_of: :attestation
  attr_readonly :runtime_image_id, :runtime_image_verification_attempt_id, :image_digest, :policy_digest, :evidence_digest, :outcome, :safe_summary, :vulnerability_database_version, :issued_at, :expires_at
  attribute :safe_summary, :json, default: -> { {} }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :image_digest, :policy_digest, :evidence_digest, format: { with: RuntimeImage::DIGEST_FORMAT }
  validates :runtime_image_verification_attempt_id, uniqueness: true
  validates :issued_at, :expires_at, presence: true
  validate :bindings_match
  scope :accepted, -> { where(outcome: "accepted") }
  scope :valid_at, ->(now = Time.current) { accepted.where(invalidated_at: nil).where("expires_at > ?", now) }
  scope :reevaluation_candidates, -> { accepted.where(invalidated_at: nil) }
  scope :exact_evidence_retention_candidates, -> { where(exact_evidence_purged_at: nil) }
  def valid_at?(now = Time.current) = outcome == "accepted" && invalidated_at.nil? && expires_at > now
  private
  def bindings_match
    return unless attempt && runtime_image
    errors.add(:runtime_image, :invalid) unless attempt.runtime_image_id == runtime_image_id
    errors.add(:image_digest, :runtime_image_digest_mismatch) unless image_digest == attempt.image_digest && image_digest == runtime_image.digest
    errors.add(:policy_digest, :invalid) unless policy_digest == attempt.policy_digest
  end
end
