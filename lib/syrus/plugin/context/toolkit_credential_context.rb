# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      ToolkitCredentialContext = Data.define(:user, :enabled) do
        def initialize(user: nil, enabled: true) = super(user:, enabled: !!enabled)
      end
    end
  end
end
