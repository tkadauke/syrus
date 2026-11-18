module ConnectedAccounts
  # Contract implemented by contributors to `connected_accounts:provider`.
  # Provider configuration belongs to the contributor's manifest; methods only
  # receive typed context objects and perform the corresponding operation.
  module Provider
    AuthorizationContext = Struct.new(:redirect_uri, :state, :requested_scopes, :read_only, :configuration, :code_challenge, keyword_init: true)
    ExchangeCodeContext = Struct.new(:code, :redirect_uri, :configuration, :code_verifier, keyword_init: true)
    RefreshContext = Struct.new(:tokens, :configuration, keyword_init: true)
    RevokeContext = Struct.new(:tokens, :configuration, keyword_init: true)
    IdentityContext = Struct.new(:access_token, :configuration, keyword_init: true)
    ValidateContext = Struct.new(:access_token, :configuration, keyword_init: true)
    EventsContext = Data.define(:headers, :body)

    REQUIRED_CAPABILITIES = %w[authorization exchange_code refresh revoke identity validate].freeze
    OPTIONAL_CAPABILITIES = %w[events].freeze
    CAPABILITIES = (REQUIRED_CAPABILITIES + OPTIONAL_CAPABILITIES).freeze
  end
end
