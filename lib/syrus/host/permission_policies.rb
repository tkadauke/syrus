require "forwardable"

module Syrus
  module Host
    # Ranks policy outcomes the way the core policy evaluator does.
    module PermissionPolicies
      def self.rank(policy) = ::Permissions::PolicyEvaluator::POLICY_RANK.fetch(policy.to_sym)
    end
  end
end
