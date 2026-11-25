# One image digest held in one worker's local container engine cache. The
# durable RuntimeImage record stays the source of truth for identity and
# revocation; this row only describes what a host happens to have on disk.
class RuntimeImageCacheEntry < ApplicationRecord
  STATES = %w[present corrupt evicting].freeze

  belongs_to :runtime_image

  validates :hostname, :digest, presence: true
  validates :state, inclusion: { in: STATES }
  validates :runtime_image_id, uniqueness: { scope: :hostname }

  scope :for_host, ->(hostname) { where(hostname: hostname) }
  scope :present, -> { where(state: "present") }
  scope :unleased, ->(now = Time.current) { where("leased_until IS NULL OR leased_until <= ?", now) }
  scope :lru, -> { order(Arel.sql("COALESCE(last_used_at, pulled_at, created_at) ASC"), :id) }

  def leased?(now = Time.current) = leased_until.present? && leased_until > now
end
