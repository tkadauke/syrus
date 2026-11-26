class RuntimeImageVerificationAttempt < ApplicationRecord
  STATES = %w[running accepted rejected blocked].freeze
  TERMINAL_STATES = STATES - [ "running" ]

  belongs_to :runtime_image
  has_many :checks, -> { order(:position) }, class_name: "RuntimeImageVerificationCheck",
           foreign_key: :runtime_image_verification_attempt_id, inverse_of: :attempt, dependent: :destroy

  attr_readonly :runtime_image_id, :number, :image_digest, :policy_snapshot, :policy_digest, :started_at
  attribute :policy_snapshot, :json, default: -> { {} }

  validates :state, inclusion: { in: STATES }
  validates :decision, inclusion: { in: %w[candidate rejected blocked] }, allow_nil: true
  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :runtime_image_id }
  validates :image_digest, :policy_digest, format: { with: RuntimeImage::DIGEST_FORMAT }
  validate :digest_matches_image

  def terminal? = TERMINAL_STATES.include?(state)
  def accepted? = state == "accepted"

  private

  def digest_matches_image
    errors.add(:image_digest, "must match the immutable runtime image") if runtime_image && image_digest != runtime_image.digest
  end
end
