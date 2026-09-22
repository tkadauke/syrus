module Api
  module V1
    module App
      module Admin
        class PlatformPollingController < BaseController
          # Starts both core PlatformPollingJob subclasses (Telegram, etc.) and
          # plugin-provided :platform_delivery connectors (e.g. Discord's
          # Gateway listener), so this is the one endpoint operators need to
          # re-prime the whole platform-delivery surface after a worker
          # restart or a pruned long-running connector job.
          def start
            connectors = PlatformPollingJob.start_all_with_status! + PlatformDelivery::Registry.start_connectors_with_status!

            render json: {
              started: connectors.select { |connector| connector[:status] == :started }.map { |connector| connector[:name] },
              connectors: connectors
            }
          end
        end
      end
    end
  end
end
