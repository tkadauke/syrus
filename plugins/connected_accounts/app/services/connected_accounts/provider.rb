module ConnectedAccounts
  # Contract implemented by contributors to `connected_accounts:provider`.
  # Provider configuration belongs to the contributor's manifest; methods only
  # receive typed context objects and perform the corresponding operation.
  module Provider
    AuthorizationContext = Data.define(:redirect_uri, :state, :requested_scopes, :read_only)
    ExchangeCodeContext = Data.define(:code, :redirect_uri)
    RefreshContext = Data.define(:tokens)
    RevokeContext = Data.define(:tokens)
    IdentityContext = Data.define(:access_token)
    ValidateContext = Data.define(:access_token)
    EventsContext = Data.define(:headers, :body)

    REQUIRED_CAPABILITIES = %w[authorization exchange_code refresh revoke identity validate].freeze
    OPTIONAL_CAPABILITIES = %w[events].freeze
    CAPABILITIES = (REQUIRED_CAPABILITIES + OPTIONAL_CAPABILITIES).freeze
  end
end
