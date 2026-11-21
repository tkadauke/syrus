# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Mutable-workspace input constructed by core for plugin capabilities.
      WorkspaceContext = Data.define(:workspace_path, :changed_files, :repository) do
        def initialize(workspace_path:, changed_files:, repository:)
          super(workspace_path:, changed_files: Array(changed_files).dup.freeze, repository:)
        end
      end
    end
  end
end
