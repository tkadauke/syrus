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

        def approval_guidelines
          raise NotImplementedError, "#{self}.approval_guidelines is required"
        end

        # Human-readable, structured disclosure shown wherever a user delegates
        # authority. It must identify who receives evidence and how it is used.
        def data_sharing_disclosure
          raise NotImplementedError, "#{self}.data_sharing_disclosure is required"
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
