class RepositoryMembership < ApplicationRecord
  ROLES = %w[owner collaborator].freeze

  belongs_to :repository
  belongs_to :user
  belongs_to :installation, optional: true

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :repository_id, message: "is already a member of this repository" }
  validates :agent_provider, inclusion: { in: -> { User.agent_providers } }, allow_nil: true

  before_validation :normalize_agent_provider

  private

  def normalize_agent_provider
    self.agent_provider = nil if agent_provider.blank?
  end
end
