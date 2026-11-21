module Syrus
  module Host
    module SystemAlert
      def self.build(**attributes)
        SystemAlerts::Alert.new(**attributes)
      end
    end
  end
end
