module CredentialStore
  module ManagementScope
    class Base
      SCOPES = {
        "user" => "CredentialStore::ManagementScope::UserScope",
        "repository" => "CredentialStore::ManagementScope::RepositoryScope",
        "team" => "CredentialStore::ManagementScope::TeamScope",
        "instance" => "CredentialStore::ManagementScope::InstanceScope"
      }.freeze

      def self.for(scope_type)
        SCOPES.fetch(scope_type.to_s).constantize.new
      end

      def can_manage?(_user, _scope_id)
        raise NotImplementedError
      end

      def label(_scope_id)
        raise NotImplementedError
      end

      def labels_for(_scope_ids)
        raise NotImplementedError
      end
    end
  end
end
