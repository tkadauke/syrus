module WorkflowOutcomeOverrides
  module Resumers
    class None
      def self.call(_override) = nil
    end
  end
end
