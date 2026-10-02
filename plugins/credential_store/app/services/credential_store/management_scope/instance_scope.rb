module CredentialStore
  module ManagementScope
    class InstanceScope < Base
      def can_manage?(_user, _scope_id)
        false
      end

      def label(_scope_id)
        "Instance"
      end

      def labels_for(scope_ids)
        scope_ids.index_with { "Instance" }
      end
    end
  end
end
