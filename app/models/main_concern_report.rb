class MainConcernReport < ApplicationRecord
  belongs_to :repository
  belongs_to :job
  belongs_to :workflow
  belongs_to :run

  validates :reason, presence: true

  scope :for_repository_since, ->(repository, since) {
    where(repository: repository).where("created_at >= ?", since)
  }
end
