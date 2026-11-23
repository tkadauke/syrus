# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      WorkContext = Data.define(:workflow, :work_unit, :job, :landing) do
        def initialize(workflow: nil, work_unit: nil, job: nil, landing: false)
          workflow ||= work_unit&.workflow
          job ||= workflow&.job || work_unit&.job
          super(workflow:, work_unit:, job:, landing: !!landing)
        end

        def landing? = landing
      end
    end
  end
end
