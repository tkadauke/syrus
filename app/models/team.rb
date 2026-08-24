class Team < ApplicationRecord
  has_many :team_memberships, dependent: :destroy
  has_many :users, through: :team_memberships
  has_many :team_repositories, dependent: :destroy
  has_many :repositories, through: :team_repositories

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  def owned_by?(user)
    return false unless user
    team_memberships.exists?(user_id: user.id, role: "owner")
  end
end
