module ConnectedAccounts
  class ProviderConfig < ApplicationRecord
    self.table_name = "connected_accounts_provider_configs"

    belongs_to :credential_store_credential, class_name: "CredentialStore::Credential"
    belongs_to :created_by, class_name: "::User"
    attribute :scopes, :json, default: -> { [] }
    attribute :api_origins, :json, default: -> { [] }

    validates :key, format: { with: /\A[a-z][a-z0-9_]*\z/ }, uniqueness: true
    validates :display_name, presence: true
    validates :authorize_url, :token_url, presence: true
    validate :validate_urls
    validate :validate_credential

    def client_credentials
      JSON.parse(credential_store_credential.payload).symbolize_keys
    rescue JSON::ParserError
      raise ArgumentError, "OAuth client credential is invalid"
    end

    private

    def validate_urls
      [ authorize_url, token_url, revoke_url, identity_url, *api_origins ].compact.each do |value|
        uri = URI.parse(value)
        errors.add(:base, "OAuth URLs must use HTTPS") unless uri.is_a?(URI::HTTPS) && uri.host.present?
      rescue URI::InvalidURIError
        errors.add(:base, "OAuth URLs must be valid absolute URLs")
      end
    end

    def validate_credential
      return unless credential_store_credential
      errors.add(:credential_store_credential, "must be an OAuth client credential") unless credential_store_credential.credential_type == "connected_accounts.oauth_client"
      errors.add(:credential_store_credential, "must be instance scoped") unless credential_store_credential.scope_type == "instance"
    end
  end
end
