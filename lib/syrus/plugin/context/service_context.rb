# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Context for service-family capabilities. Services keep their own large
      # stateful interfaces, so the context only says whether the declaring
      # provider is currently offering its services; per-repository or
      # per-request selection stays with the service's own +available_for?+.
      ServiceContext = Data.define(:enabled) do
        def initialize(enabled: true) = super(enabled:)
      end
    end
  end
end
