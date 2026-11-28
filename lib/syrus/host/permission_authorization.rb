module Syrus
  module Host
    # Stable plugin boundary for evaluating one already-registered permission
    # descriptor without exposing core rule, lease, or evaluator objects.
    module PermissionAuthorization
      Result = Data.define(:decision, :lease_expires_at) do
        def allow? = decision == :allow
        def ask? = decision == :ask
        def deny? = decision == :deny
      end

      def self.call(owner:, descriptor:, role:, arguments:, context:, consume: true)
        management = Permissions::Management.new(owner)
        authorization = if consume
          management.authorize(descriptor:, role:, resource_scope: {}, arguments:, context:)
        else
          decision = management.explain(descriptor:, role:, resource_scope: {}, arguments:, context:)
          Struct.new(:decision, :lease).new(decision, nil)
        end
        Result.new(decision: authorization.decision.policy, lease_expires_at: authorization.lease&.expires_at)
      end
    end
  end
end
