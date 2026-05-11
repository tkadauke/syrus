class Installation < ApplicationRecord
  encrypts :cached_token

  belongs_to :user
  has_many :repositories, dependent: :nullify

  validates :github_installation_id, presence: true, uniqueness: true
  validates :account_login, presence: true
  validates :account_id, presence: true
  validates :account_type, presence: true, inclusion: { in: %w[User Organization] }
  validates :installed_at, presence: true

  scope :active, -> { where(removed_at: nil) }
end
