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

      def self.visible_relation(relation, context)
        SCOPES.keys.reduce(relation.none) do |visible, scope_type|
          visible.or(self.for(scope_type).visible_relation(relation, context))
        end
      end

      def validate!(credential)
        raise NotImplementedError
      end

      def usable_by?(credential, context)
        visible_scope_ids(context).include?(normalized_scope_id(credential.scope_id))
      end

      def visible_relation(relation, context)
        relation.where(scope_type: scope_type, scope_id: visible_scope_ids(context))
      end

      def resolution_precedence
        raise NotImplementedError
      end

      def record_for(scope_id)
        return nil if scope_id.blank?

        model_class.find_by(id: scope_id)
      end

      private

      def visible_scope_ids(_context)
        raise NotImplementedError
      end

      def scope_type
        self.class.name.demodulize.delete_suffix("Scope").underscore
      end

      def normalized_scope_id(scope_id)
        scope_id.presence&.to_i
      end

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
