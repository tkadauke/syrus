class TeamRepository < ApplicationRecord
  # Ordered low to high -- mirrors RepositoryMembership::ROLES/ROLE_RANK.
  ROLES = RepositoryMembership::ROLES
  ROLE_RANK = RepositoryMembership::ROLE_RANK

  belongs_to :team
  belongs_to :repository

  validates :role, inclusion: { in: ROLES }
  validates :team_id, uniqueness: { scope: :repository_id, message: "already has a grant on this repository" }

  # Grants whose role tier is at least `tier` (e.g. `at_least("write")`
  # matches both "write" and "admin" rows). Mirrors RepositoryMembership.at_least.
  scope :at_least, ->(tier) { where(role: ROLES.drop(ROLE_RANK.fetch(tier.to_s))) }
end
