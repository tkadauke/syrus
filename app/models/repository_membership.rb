class RepositoryMembership < ApplicationRecord
  ROLES = %w[owner collaborator].freeze

  belongs_to :repository
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :repository_id, message: "is already a member of this repository" }
end
