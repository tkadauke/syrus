# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      RepairContext = Data.define(:workflow, :run, :failed_steps) do
        def initialize(workflow: nil, run: nil, failed_steps: [])
          workflow ||= run&.workflow
          super(workflow:, run:, failed_steps: Array(failed_steps).freeze)
        end
      end
    end
  end
end
