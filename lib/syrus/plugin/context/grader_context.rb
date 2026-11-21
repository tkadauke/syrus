# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Grader invocation input constructed by core for plugin capabilities.
      GraderContext = Data.define(
        :name, :command, :workspace_path, :failed_cases, :base_retry, :project_path,
        :config, :default_failures, :text, :step_name, :test_case, :operation
      ) do
        def initialize(name: nil, command: nil, workspace_path: nil, failed_cases: [], base_retry: nil, project_path: nil,
          config: nil, default_failures: nil, text: nil, step_name: nil, test_case: nil, operation: nil)
          super(name:, command:, workspace_path:, failed_cases: Array(failed_cases).dup.freeze, base_retry:, project_path:,
            config:, default_failures:, text:, step_name:, test_case:, operation:)
        end
      end
    end
  end
end
