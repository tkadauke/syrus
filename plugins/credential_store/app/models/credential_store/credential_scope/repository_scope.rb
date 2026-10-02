module CredentialStore
  module CredentialScope
    class RepositoryScope < Base
      def validate!(credential)
        require_scope_id!(credential)
        require_existing_record!(credential)
      end

      private

      def model_class = ::Repository
    end
  end
end
