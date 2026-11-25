# Durable record of one immutable image digest published through the Runtime
# Image Service. The digest, platform, namespace, and source identity never
# change after creation; only availability, revocation, and retention evolve.
class RuntimeImage < ApplicationRecord
  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/

  AVAILABILITIES = %w[pending available revoked deleted].freeze
  RETENTION_STATES = %w[default retained expired].freeze
  # An image can only move forward: pending -> available -> revoked -> deleted.
  AVAILABILITY_TRANSITIONS = {
    "pending" => %w[available deleted],
    "available" => %w[revoked deleted],
    "revoked" => %w[deleted],
    "deleted" => []
  }.freeze

  class InvalidTransition < StandardError; end

  belongs_to :runtime_image_namespace
  attr_readonly :runtime_image_namespace_id, :digest, :platform, :source_kind, :source_ref, :source_digest

  validates :digest, presence: true, format: { with: DIGEST_FORMAT }
  validates :platform, :source_kind, :source_ref, presence: true
  validates :source_digest, format: { with: DIGEST_FORMAT }, allow_blank: true
  validates :availability, inclusion: { in: AVAILABILITIES }
  validates :retention_state, inclusion: { in: RETENTION_STATES }
  validates :digest, uniqueness: { scope: %i[runtime_image_namespace_id platform] }
  validate :provenance_must_be_hash

  after_initialize { self.provenance = {} if provenance.nil? && has_attribute?(:provenance) }

  scope :available, -> { where(availability: "available") }
  scope :revoked, -> { where(availability: "revoked") }
  scope :pullable, -> { available.where(revoked_at: nil) }
  # Garbage-collection candidates before age is applied: stored images that
  # no retention hold protects. Age, namespace overrides, and the "keep the
  # newest image" rule are applied by RuntimeImages::Collector.
  scope :prunable, lambda { |now = Time.current|
    where(availability: %w[available revoked]).where.not(published_at: nil)
      .where("retention_state <> 'retained' OR (retain_until IS NOT NULL AND retain_until <= ?)", now)
  }
  scope :cleanup_failed, -> { where("cleanup_failure_count > 0").where.not(availability: "deleted") }
  scope :retention_expired, ->(now = Time.current) { where(retention_state: "retained").where(retain_until: ..now) }

  AVAILABILITIES.each do |name|
    define_method(:"#{name}?") { availability == name }
  end

  def pullable? = available? && revoked_at.nil?
  def retained?(now = Time.current) = retention_state == "retained" && (retain_until.nil? || retain_until > now)

  def mark_available!(locator: nil, now: Time.current)
    transition_to!("available", locator: locator || self.locator, published_at: published_at || now)
  end

  def mark_revoked!(reason:, now: Time.current)
    transition_to!("revoked", revoked_at: now, revoked_reason: reason.to_s.truncate(500))
  end

  def mark_deleted!(now: Time.current)
    transition_to!("deleted", deleted_at: now)
  end

  def retain!(reason: nil, until_time: nil)
    raise InvalidTransition, "deleted images cannot be retained" if deleted?
    update!(retention_state: "retained", retain_until: until_time, retention_reason: reason.to_s.truncate(500).presence)
  end

  def record_cleanup_failure!(error, now: Time.current)
    update!(cleanup_failure_count: cleanup_failure_count + 1, cleanup_failed_at: now,
            cleanup_last_error: "#{error.class}: #{error.message}".truncate(500))
  end

  def clear_cleanup_failure!
    return if cleanup_failure_count.zero? && cleanup_last_error.nil?
    update!(cleanup_failure_count: 0, cleanup_failed_at: nil, cleanup_last_error: nil)
  end

  def release_retention!
    update!(retention_state: "default", retain_until: nil, retention_reason: nil)
  end

  private

  def transition_to!(target, attrs)
    unless AVAILABILITY_TRANSITIONS.fetch(availability).include?(target)
      raise InvalidTransition, "cannot move runtime image from #{availability} to #{target}"
    end
    update!(attrs.merge(availability: target))
  end

  def provenance_must_be_hash
    errors.add(:provenance, :invalid) unless provenance.is_a?(Hash)
  end
end
