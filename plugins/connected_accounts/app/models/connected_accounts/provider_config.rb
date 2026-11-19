module ConnectedAccounts
  class ProviderConfig < ApplicationRecord
    self.table_name = "connected_accounts_provider_configs"
    encrypts :client_secret
    attribute :scope_catalog, :json, default: -> { [] }
    attribute :api_origins, :json, default: -> { [] }

    validates :provider_key, :authorize_url, :token_url, :identity_url, :client_id, :client_secret, presence: true
    validates :provider_key, uniqueness: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
    validate :https_urls

    private

    def https_urls
      values = [ authorize_url, token_url, revoke_url, identity_url, validate_url, *Array(api_origins) ].compact_blank
      errors.add(:base, "provider URLs must use HTTPS") unless values.all? { |value| URI.parse(value).is_a?(URI::HTTPS) }
    rescue URI::InvalidURIError
      errors.add(:base, "provider URL is invalid")
    end
  end
end
