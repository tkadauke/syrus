class Coworkers::WorkspaceRepository < ApplicationRecord
  self.table_name = "coworker_workspace_repositories"

  belongs_to :repository
end
