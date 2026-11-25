# One published coworker base image's place in the promotion lifecycle:
# candidate -> active -> retired, or revoked from any state. The image itself is
# immutable (RuntimeImage); this record says whether new coworker turns may be
# launched from it, for how long older environments built on it stay
# supported, and why it was withdrawn.
#
# State changes go through RuntimeImages::BaseReleases, which audits them and
# keeps the Runtime Image Service's own revocation and retention in step.
class CoworkerBaseRelease < ApplicationRecord
  STATUSES = %w[candidate active retired revoked].freeze
  # standard: no new launches. severe: additionally terminate running turns.
  SEVERITIES = %w[standard severe].freeze

  belongs_to :runtime_image
  attr_readonly :runtime_image_id, :platform, :generation, :runtime_abi, :compat_min, :compat_max

  validates :platform, presence: true
  validates :generation, :runtime_abi, :compat_min, :compat_max, numericality: { only_integer: true }
  validates :status, inclusion: { in: STATUSES }
  validates :revocation_severity, inclusion: { in: SEVERITIES }, allow_nil: true
  validates :runtime_image_id, uniqueness: true
  validate :active_key_matches_status

  scope :active, -> { where(status: "active") }
  scope :candidates, -> { where(status: "candidate") }
  scope :retired, -> { where(status: "retired") }
  scope :revoked, -> { where(status: "revoked") }
  scope :severely_revoked, -> { revoked.where(revocation_severity: "severe") }
  scope :for_platform, ->(platform) { where(platform: platform) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  STATUSES.each { |name| define_method(:"#{name}?") { status == name } }

  def severe? = revoked? && revocation_severity == "severe"
  def digest = runtime_image.digest

  # True while environments built on this base may keep running: the release
  # is not revoked and any declared support deadline has not passed.
  def supported?(now = Time.current)
    !revoked? && (supported_until.nil? || supported_until > now)
  end

  # The ABI versions environments built on this base may declare.
  def compatibility_range = compat_min..compat_max

  private

  def active_key_matches_status
    expected = active? ? platform : nil
    errors.add(:active_key, :invalid) unless active_key == expected
  end
end
