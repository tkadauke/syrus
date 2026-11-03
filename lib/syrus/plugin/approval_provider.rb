module Syrus
  module Plugin
    # Contract for optional plugins that may decide an already-pending exact
    # invocation on behalf of a user. Registration never grants authority;
    # core also requires an active ApprovalProviderDelegation.
    module ApprovalProvider
      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def provider_key
          raise NotImplementedError, "#{self}.provider_key is required"
        end

        def display_name
          raise NotImplementedError, "#{self}.display_name is required"
        end

        # Operator-facing disclosure of where evidence is processed and what
        # the provider retains. Delegation surfaces must present this value.
        def data_sharing
          raise NotImplementedError, "#{self}.data_sharing is required"
        end

        def default_guidance
          raise NotImplementedError, "#{self}.default_guidance is required"
        end

        # The provider owns its own cost and rate policy. It reports a bounded
        # structured outcome instead of exposing provider-specific exceptions
        # or asking core to interpret quotas.
        def decide(_evidence)
          raise NotImplementedError, "#{self}.decide is required"
        end
      end
    end
  end
end
