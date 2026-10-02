module CredentialStore
  class Broker
    Lease = Struct.new(
      :id, :credential_id, :credential_name, :credential_type,
      :issued_at, :expires_at, :purpose, :tool_name,
      keyword_init: true
    ) do
      def expired?
        Time.current >= expires_at
      end

      def metadata
        {
          lease_id: id,
          credential_id: credential_id,
          credential_name: credential_name,
          credential_type: credential_type,
          issued_at: issued_at.iso8601,
          expires_at: expires_at.iso8601,
          purpose: purpose,
          tool_name: tool_name
        }.compact
      end
    end
  end
end
