module Syrus
  module Plugin
    module SystemAlertProvider
      extend ActiveSupport::Concern

      class_methods do
        def system_alerts
          raise NotImplementedError, "#{name} must implement .system_alerts"
        end
      end
    end
  end
end
