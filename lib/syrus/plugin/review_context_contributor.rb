module Syrus
  module Plugin
    # Restricted context and post-verdict persistence for an opaque reviewer
    # target. Core orchestrates the lifecycle but never receives a plugin model.
    module ReviewContextContributor
      def self.included(base) = base.extend(DefaultMethods)

      module DefaultMethods
        def tool_set(_target) = nil
        def tool_capability(_target) = nil
        def retention(_target) = {}
        def tombstone(_target, reason:) = nil
      end
    end
  end
end
