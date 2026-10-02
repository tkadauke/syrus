module CredentialStore
  module CredentialScope
    class UserScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def usable_by?(credential, context)
        context.user.present? && (context.user.admin? || credential.scope_id.to_i == context.user.id)
      end

      private

      def model_class = ::User
    end
  end
end
