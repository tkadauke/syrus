module MainBranchHealth
  class RepositoryState < ApplicationRecord
    self.table_name = "main_branch_health_repository_states"

    belongs_to :repository, inverse_of: :main_branch_health_state
    validates :repository_id, uniqueness: true
  end
end
