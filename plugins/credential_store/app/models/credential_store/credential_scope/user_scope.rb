module CredentialStore
  module CredentialScope
    class UserScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      def resolution_precedence = 0

      private

      def visible_scope_ids(context)
        [ context.user&.id ].compact
      end

      def model_class = ::User
    end
  end
end
