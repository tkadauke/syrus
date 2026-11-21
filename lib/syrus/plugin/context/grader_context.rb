# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Grader invocation input constructed by core for plugin capabilities.
      GraderContext = Data.define(
        :name, :command, :workspace_path, :failed_cases, :base_retry, :project_path
      ) do
        def initialize(name:, command:, workspace_path:, failed_cases:, base_retry:, project_path:)
          super(name:, command:, workspace_path:, failed_cases: Array(failed_cases).dup.freeze, base_retry:, project_path:)
        end
      end
    end
  end
end
