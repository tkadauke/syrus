# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      ToolkitRunContext = Data.define(:run, :role, :enabled) do
        def initialize(run:, role:, enabled: true) = super(run:, role:, enabled: !!enabled)
      end
    end
  end
end
