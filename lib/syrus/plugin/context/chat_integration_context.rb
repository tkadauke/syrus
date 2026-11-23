# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      ChatIntegrationContext = Data.define(:enabled) do
        def initialize(enabled: true) = super(enabled:)
      end
    end
  end
end
