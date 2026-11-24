module Syrus
  module Host
    # Reads instance feature flags by name. Flag storage and defaults are not
    # promised.
    module FeatureFlags
      def self.enabled?(flag) = ::Feature.public_send("#{flag}_enabled?")
    end
  end
end
