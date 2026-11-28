module Syrus
  module Host
    module Invariants
      def self.open_violations_alert
        SystemAlerts.invariant_violations_alert
      end
    end
  end
end
