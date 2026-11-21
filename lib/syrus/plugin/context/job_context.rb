# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Job-scoped input constructed by core for plugin capabilities.
      JobContext = Data.define(:repository, :job)
    end
  end
end
