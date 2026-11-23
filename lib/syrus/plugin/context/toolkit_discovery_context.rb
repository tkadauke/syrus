# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      ToolkitDiscoveryContext = Data.define(:enabled) do
        def initialize(enabled: true) = super(enabled: !!enabled)
      end
    end
  end
end
