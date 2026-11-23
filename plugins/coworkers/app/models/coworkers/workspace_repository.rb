class Coworkers::WorkspaceRepository < Syrus::Host::Record
  self.table_name = "coworker_workspace_repositories"

  belongs_to :repository
end
