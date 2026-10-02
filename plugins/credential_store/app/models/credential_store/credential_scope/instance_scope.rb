module CredentialStore
  module CredentialScope
    class InstanceScope < Base
      def validate!(credential)
        credential.errors.add(:scope_id, "must be nil for instance scope") if credential.scope_id.present?
      end

      def record_for(_scope_id)
        nil
      end
    end
  end
end
