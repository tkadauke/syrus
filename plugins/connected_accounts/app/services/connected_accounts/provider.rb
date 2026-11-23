module ConnectedAccounts
  # Contract implemented by contributors to `connected_accounts:provider`.
  # Provider configuration belongs to the contributor's manifest; methods only
  # receive typed context objects and perform the corresponding operation.
  module Provider
    AuthorizationContext = Data.define(:redirect_uri, :state, :requested_scopes, :read_only, :code_verifier) do
      def initialize(redirect_uri:, state:, requested_scopes:, read_only:, code_verifier: nil) = super
    end
    ExchangeCodeContext = Data.define(:code, :redirect_uri, :code_verifier) do
      def initialize(code:, redirect_uri:, code_verifier: nil) = super
    end
    RefreshContext = Data.define(:tokens)
    RevokeContext = Data.define(:tokens)
    IdentityContext = Data.define(:access_token)
    ValidateContext = Data.define(:access_token)
    EventsContext = Data.define(:headers, :body)
    SystemInvocationContext = Data.define(:access, :identity, :purpose, :target, :input)

    REQUIRED_CAPABILITIES = %w[authorization exchange_code refresh revoke identity validate].freeze
    OPTIONAL_CAPABILITIES = %w[events].freeze
    CAPABILITIES = (REQUIRED_CAPABILITIES + OPTIONAL_CAPABILITIES).freeze
    class TransientError < StandardError; end
    class PermanentError < StandardError; end
  end
end
