module MainBranchHealth
  class ConcernReport < ApplicationRecord
    self.table_name = "main_branch_health_concern_reports"
    belongs_to :repository
    belongs_to :job
    belongs_to :workflow
    belongs_to :run

    validates :reason, presence: true

    scope :for_repository_since, ->(repository, since) {
      where(repository: repository).where("created_at >= ?", since)
    }

    scope :for_observed_sha, ->(sha) {
      where(observed_sha: sha)
    }
  end
end
