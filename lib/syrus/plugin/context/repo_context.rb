# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Repository-scoped input constructed by core for plugin capabilities.
      #
      # New fields may be added without changing capability method signatures;
      # providers receive the whole context and read only the fields they need.
      RepoContext = Data.define(:repo_path, :repository, :config) do
        def initialize(repo_path:, repository: nil, config: nil)
          super(repo_path:, repository:, config:)
        end
      end
    end
  end
end
