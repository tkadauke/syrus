# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Mutable-workspace input constructed by core for plugin capabilities.
      WorkspaceContext = Data.define(:workspace_path, :changed_files, :repository, :artifact_path, :format_hint) do
        def initialize(workspace_path:, changed_files: [], repository: nil, artifact_path: nil, format_hint: nil)
          super(workspace_path:, changed_files: Array(changed_files).dup.freeze, repository:, artifact_path:, format_hint:)
        end
      end
    end
  end
end
