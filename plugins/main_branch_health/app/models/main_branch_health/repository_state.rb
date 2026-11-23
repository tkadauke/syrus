module MainBranchHealth
  class RepositoryState < ApplicationRecord
    self.table_name = "main_branch_health_repository_states"

    belongs_to :repository
    validates :repository_id, uniqueness: true
  end
end
