class RepositoryFinalApprover < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  validates :user_id, uniqueness: { scope: :repository_id }
end
