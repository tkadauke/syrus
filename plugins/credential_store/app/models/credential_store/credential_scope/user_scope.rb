module CredentialStore
  module CredentialScope
    class UserScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def usable_by?(credential, context)
        return false unless context.user

        context.user.admin? || credential.scope_id.to_i == context.user.id
      end

      def resolution_precedence = 0

      private

      def model_class = ::User
    end
  end
end
