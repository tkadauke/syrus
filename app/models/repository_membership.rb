class RepositoryMembership < ApplicationRecord
  # Ordered low to high -- see #at_least? and .at_least.
  ROLES = %w[read write admin].freeze
  ROLE_RANK = ROLES.each_with_index.to_h.freeze

  belongs_to :repository
  belongs_to :user
  belongs_to :installation, optional: true

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :repository_id, message: "is already a member of this repository" }
  validates :agent_provider, inclusion: { in: -> { User.agent_providers } }, allow_nil: true

  before_validation :normalize_agent_provider

  # Memberships whose role tier is at least `tier` (e.g. `at_least("write")`
  # matches both "write" and "admin" rows).
  scope :at_least, ->(tier) { where(role: ROLES.drop(ROLE_RANK.fetch(tier.to_s))) }

  def at_least?(tier)
    ROLE_RANK.fetch(role, -1) >= ROLE_RANK.fetch(tier.to_s, 0)
  end

  private

  def normalize_agent_provider
    self.agent_provider = nil if agent_provider.blank?
  end
end
