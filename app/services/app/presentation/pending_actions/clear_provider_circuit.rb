module App
  module Presentation
    module PendingActions
      class ClearProviderCircuit < Base
        action_key "clear_provider_circuit"

        def label
          "Clear #{payload['provider']} circuit for user ##{payload['user_id']}"
        end

        def detail
          "Mode: #{payload.fetch('mode', 'clear')}"
        end
      end
    end
  end
end
