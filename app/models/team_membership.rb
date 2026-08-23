class TeamMembership < ApplicationRecord
  # Ordered low to high, matching RepositoryMembership's convention -- an
  # owner can manage the team's membership and repository grants.
  ROLES = %w[member owner].freeze

  belongs_to :team
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :team_id, message: "is already a member of this team" }
end
