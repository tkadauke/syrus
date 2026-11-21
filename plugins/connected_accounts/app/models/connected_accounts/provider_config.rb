module ConnectedAccounts
  class ProviderConfig < ApplicationRecord
    self.table_name = "connected_accounts_provider_configs"
    encrypts :client_secret
    attribute :scope_catalog, :json, default: -> { [] }
    attribute :read_only_scopes, :json, default: -> { [] }
    attribute :api_origins, :json, default: -> { [] }
    attribute :allow_as_owner, :boolean, default: false

    validates :provider_key, :authorize_url, :token_url, :identity_url, :client_id, :client_secret, presence: true
    validates :provider_key, uniqueness: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
    validate :https_urls
    validate :read_only_scopes_are_configured

    private

    def https_urls
      values = [ authorize_url, token_url, revoke_url, identity_url, validate_url, *Array(api_origins) ].compact_blank
      errors.add(:base, I18n.t("connected_accounts.errors.https_urls")) unless values.all? { |value| URI.parse(value).is_a?(URI::HTTPS) }
    rescue URI::InvalidURIError
      errors.add(:base, I18n.t("connected_accounts.errors.invalid_url"))
    end

    def read_only_scopes_are_configured
      unknown = Array(read_only_scopes).map(&:to_s) - Array(scope_catalog).map(&:to_s)
      errors.add(:read_only_scopes, I18n.t("connected_accounts.settings.read_only_scopes_not_in_catalog")) if unknown.any?
    end
  end
end
