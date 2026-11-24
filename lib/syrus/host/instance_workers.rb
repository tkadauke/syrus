module Syrus
  module Host
    # Reports the worker processes the instance has recently heard from.
    # Version bookkeeping is not promised.
    module InstanceWorkers
      def self.fresh = ::InstanceVersion.fresh.where(role: "worker")
    end
  end
end
