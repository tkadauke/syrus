# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Repository-scoped input constructed by core for plugin capabilities.
      #
      # New fields may be added without changing capability method signatures;
      # providers receive the whole context and read only the fields they need.
      RepoContext = Data.define(:repo_path, :repository)
    end
  end
end
