module CredentialStore
  module ManagementScope
    class InstanceScope < Base
      def can_manage?(_user, _scope_id)
        false
      end

      def label(_scope_id)
        "Instance"
      end
    end
  end
end
