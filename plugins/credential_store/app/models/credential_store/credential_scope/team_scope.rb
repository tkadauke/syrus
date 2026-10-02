module CredentialStore
  module CredentialScope
    class TeamScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      private

      def model_class = ::Team
    end
  end
end
