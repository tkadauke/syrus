require "json"

module ConnectedAccounts
  class AccountClient
    BROKER_TOOL_NAME = "connected_accounts.account_client".freeze
    PURPOSE_MAX_LENGTH = 255

    class Error < StandardError; end
    class NotAccessible < Error; end
    class InvalidAccount < Error; end
    class UnauthorizedInvocation < Error; end

    class << self
      def with_access(account:, acting_mode:, scopes:, purpose:)
        new(account:, acting_mode:, scopes:, purpose:).with_access { |access| yield access }
      end
    end

    def initialize(account:, acting_mode:, scopes:, purpose:)
      @account_ref = account
      @acting_mode = acting_mode.to_s
      @requested_scopes = normalize_scopes(scopes)
      @purpose = purpose.to_s
      @token_secrets = []
    end

    def with_access
      account = resolve_account!
      context = current_context!
      ensure_owner!(account, context)
      authorization = authorized_invocation!(context)
      credential = account.credential
      api_origins = Array(credential.target_constraints.to_h["allowed_url_prefixes"])
      access = nil

      result = CredentialStore::Broker.with_credential_value(
        context:,
        credential: credential.id,
        type: "connected_accounts.oauth",
        purpose: redacted_purpose,
        tool_name: BROKER_TOOL_NAME,
        target: { url: api_origins.first },
        credential_validator: ->(candidate) { validation_denial(account, candidate) },
        attempt_metadata: {
          provider: account.provider_key,
          account_id: account.id,
          acting_mode: acting_mode,
          scopes: requested_scopes,
          authorized_invocation: authorization.slice("tool_name", "invocation_fingerprint")
        },
        extra_secrets: token_secrets
      ) do |payload, lease_metadata|
        tokens = parse_payload!(payload)
        access = Access.new(
          token: tokens.fetch("access_token"),
          expires_at: parse_expiry(tokens["expires_at"]),
          scopes: requested_scopes,
          api_origins:
        )
        yield access
      ensure
        access&.revoke!
      end

      result
    end

    private

    attr_reader :account_ref, :acting_mode, :requested_scopes, :purpose, :token_secrets

    def current_context!
      context = Mcp::Tools::AuthorizationSupport.current_mcp_context
      context ||= begin
        server_context = Mcp::Tools::AuthorizationSupport.current_server_context
        McpToolContext.from_server_context(server_context) if server_context
      end
      context || raise(UnauthorizedInvocation, "account access requires an authorized tool invocation")
    end

    def resolve_account!
      return account_ref if account_ref.is_a?(Account)

      Account.find(account_ref)
    rescue ActiveRecord::RecordNotFound
      raise NotAccessible, "connected account is not accessible"
    end

    def ensure_owner!(account, context)
      raise NotAccessible, "connected account is not accessible" unless context.user && account.owner_user_id == context.user.id
    end

    def authorized_invocation!(context)
      server_authorization = Mcp::Tools::AuthorizationSupport.current_server_context
        .to_h.fetch(:permission_authorization, {})
      authorization = context.permission_authorization.to_h
        .merge(server_authorization.to_h)
        .stringify_keys
      unless authorization["tool_name"].present? && authorization["invocation_fingerprint"].present?
        raise UnauthorizedInvocation, "account access requires an authorized tool invocation"
      end

      authorization
    end

    def validation_denial(account, credential)
      parse_payload!(credential.payload)
      return "account is not connected" unless account.connected?
      return "acting mode is not eligible" unless account.permits_acting_mode?(acting_mode)
      return "requested scopes exceed the account grant or ceiling" unless account.permits_scopes?(requested_scopes)
      return "credential does not belong to account owner" unless credential.owner_user_id == account.owner_user_id

      nil
    end

    def parse_payload!(payload)
      parsed = JSON.parse(payload)
      access_token = parsed["access_token"].to_s
      refresh_token = parsed["refresh_token"].to_s
      raise InvalidAccount, "OAuth credential has no access token" if access_token.blank?

      token_secrets.concat([ access_token, refresh_token ]).compact_blank!.uniq!
      parsed
    rescue JSON::ParserError, TypeError
      raise InvalidAccount, "OAuth credential payload is invalid"
    end

    def redacted_purpose
      CredentialStore::Broker.redact(purpose, extra_secrets: token_secrets).truncate(PURPOSE_MAX_LENGTH)
    end

    def normalize_scopes(scopes)
      Array(scopes).filter_map { |scope| scope.to_s.strip.presence }.uniq.sort
    end

    def parse_expiry(value)
      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end
  end
end
