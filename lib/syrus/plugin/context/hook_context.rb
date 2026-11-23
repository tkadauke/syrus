# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      # Context for the hook families (Lifecycle and DataPolicy). Hooks are
      # selected once and then invoked by core with their own arguments, so the
      # context only says whether the contribution is being requested for use.
      HookContext = Data.define(:enabled) do
        def initialize(enabled: true) = super(enabled:)
      end
    end
  end
end
