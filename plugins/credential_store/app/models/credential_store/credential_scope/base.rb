module CredentialStore
  module CredentialScope
    class Base
      SCOPES = {
        "user" => "CredentialStore::CredentialScope::UserScope",
        "repository" => "CredentialStore::CredentialScope::RepositoryScope",
        "team" => "CredentialStore::CredentialScope::TeamScope",
        "instance" => "CredentialStore::CredentialScope::InstanceScope"
      }.freeze

      def self.for(scope_type)
        SCOPES.fetch(scope_type.to_s).constantize.new
      end

      def validate!(credential)
        raise NotImplementedError
      end

      def usable_by?(_credential, _context)
        raise NotImplementedError
      end

      def record_for(scope_id)
        return nil if scope_id.blank?

        model_class.find_by(id: scope_id)
      end

      private

      def require_scope_id!(credential)
        credential.errors.add(:scope_id, "must be present for #{credential.scope_type} scope") if credential.scope_id.blank?
      end

      def require_existing_record!(credential)
        return if credential.scope_id.blank?
        return if record_for(credential.scope_id)

        credential.errors.add(:scope_id, "must reference an existing #{credential.scope_type}")
      end

      def model_class
        raise NotImplementedError
      end
    end
  end
end
