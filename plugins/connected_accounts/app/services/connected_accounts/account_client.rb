module ConnectedAccounts
  class AccountClient
    CREDENTIAL_TYPE = "connected_accounts.oauth".freeze
    BROKER_TOOL_NAME = "connected_accounts.broker".freeze
    PURPOSE_REDACTION = "[purpose redacted]".freeze
    EXPIRY_SKEW = 30.seconds

    class Error < StandardError; end
    class Denied < Error; end

    class_attribute :refresh_handler, instance_writer: false
    class << self
      def with_access(account:, acting_mode:, scopes:, purpose:, context: nil, target: {})
        new(account:, acting_mode:, scopes:, purpose:, context:, target:).with_access { |access| yield access }
      end


      def with_system_access(account:, service_capability:, scopes:, purpose:, target: {}, &block)
        SystemInvocation.call(account:, service_capability:, scopes:, purpose:, target:, &block)
      end
    end

    def initialize(account:, acting_mode:, scopes:, purpose:, context:, target:)
      @account_ref = account
      @acting_mode = acting_mode.to_s
      @scopes = Array(scopes).map(&:to_s).uniq.sort
      @purpose = purpose.to_s
      @context = context || inferred_context(account)
      @target = target.to_h
    end

    def with_access
      account = resolve_account!
      @target = default_target(account) if target.blank?
      validate_owner!(account)
      validate_invocation!
      access_yielded = false

      CredentialStore::Broker.with_credential_payload(
        context: context,
        credential: account.credential_store_credential_id,
        type: CREDENTIAL_TYPE,
        purpose: redacted_purpose,
        tool_name: BROKER_TOOL_NAME,
        target: target,
        credential_validator: ->(_credential) { account_denial_reason(account) },
        attempt_metadata: audit_metadata(account)
      ) do |payload, _lease|
        tokens = parse_payload!(payload)
        secrets = token_secrets(tokens)
        tokens = refresh_tokens!(account, tokens) if token_expired?(tokens)
        secrets |= token_secrets(tokens)
        access = Access.new(tokens.fetch("access_token"))
        access_yielded = true
        result = yield access
        CredentialStore::Broker.redact(result, extra_secrets: secrets)
      rescue StandardError => e
        raise e.class, CredentialStore::Broker.redact(e.message, extra_secrets: secrets || token_secrets(tokens))
      end
    rescue CredentialStore::Broker::Denied, CredentialStore::Broker::NotFound => e
      raise Denied, e.message
    rescue CredentialStore::Broker::ExecutionError => e
      raise if access_yielded || !e.cause.is_a?(CredentialStore::Broker::InvalidPayload)

      raise Denied, e.message
    end

    private

    attr_reader :account_ref, :acting_mode, :scopes, :purpose, :context, :target

    def default_target(account)
      origin = ProviderConfig.find_by(provider_key: account.provider)&.api_origins&.first
      origin.present? ? { url: origin } : {}
    end

    def inferred_context(account)
      return account.context if account.respond_to?(:context)

      McpToolContext.new(surface: :api, role: nil, user: Current.user)
    end

    def resolve_account!
      account = account_ref.is_a?(Account) ? account_ref : Account.find_by(id: account_ref)
      raise Denied, "connected account not found" unless account

      account
    end

    def validate_owner!(account)
      account.owner_policy.validate_access!(account, context)
    end

    def validate_invocation!
      return if context.permission_authorization["system_service_identity"].present?
      raise Denied, "authorized invocation reference is required" if context.permission_authorization.blank?
      if coworker_context? && !Feature.coworker_connected_accounts_enabled?
        raise Denied, "coworker connected account access is disabled"
      end
    end

    def coworker_context?
      [ AgentRole::COWORKER, AgentRole::COWORKER_CHAT ].include?(context.role)
    end

    def account_denial_reason(account)
      return "account is not connected" unless account.connected?
      return "acting as the account owner is disabled" if acting_mode == "as_owner" && !account.acting_mode_enabled?(acting_mode)
      return "acting mode is not eligible" unless account.acting_mode_enabled?(acting_mode)
      return "requested scopes exceed the account grant" unless (scopes - account.granted_scopes).empty?
      "requested scopes exceed the account ceiling" unless (scopes - account.effective_scope_ceiling).empty?
    end

    def parse_payload!(payload)
      value = JSON.parse(payload)
      raise CredentialStore::Broker::InvalidPayload, "OAuth credential payload is invalid" unless value.is_a?(Hash)
      raise CredentialStore::Broker::InvalidPayload, "OAuth access token is unavailable" if value["access_token"].blank?

      value
    rescue JSON::ParserError
      raise CredentialStore::Broker::InvalidPayload, "OAuth credential payload is invalid"
    end

    def token_expired?(tokens)
      return false if tokens["expires_at"].blank?
      expires_at = Time.iso8601(tokens.fetch("expires_at"))
      expires_at <= EXPIRY_SKEW.from_now
    rescue KeyError, ArgumentError
      raise CredentialStore::Broker::InvalidPayload, "OAuth credential expiry is invalid"
    end

    def refresh_tokens!(account, tokens)
      handler = self.class.refresh_handler
      raise CredentialStore::Broker::InvalidPayload, "OAuth access token has expired" unless handler

      refreshed = CredentialStore::Broker.refresh_credential!(
        credential: account.credential_store_credential_id,
        plugin_name: "connected_accounts",
        purpose: PURPOSE_REDACTION,
        user: context.user,
        metadata: audit_metadata(account)
      ) do |current_payload|
        current_tokens = parse_payload!(current_payload)
        replacement = handler.call(account: account, tokens: current_tokens.dup)
        replacement_payload = JSON.generate(replacement)
        replacement_tokens = parse_payload!(replacement_payload)
        if token_expired?(replacement_tokens)
          raise CredentialStore::Broker::InvalidPayload, "refreshed OAuth access token is expired"
        end
        replacement_payload
      end
      parse_payload!(refreshed.payload)
    end

    def token_secrets(tokens)
      tokens&.values_at("access_token", "refresh_token") || []
    end

    def redacted_purpose
      return nil if purpose.blank?
      return purpose.truncate(255) if context.permission_authorization["system_service_identity"].present?
      PURPOSE_REDACTION
    end

    def audit_metadata(account)
      {
        provider: account.provider,
        connected_account_id: account.id,
        acting_mode: acting_mode,
        scopes: scopes,
        purpose: redacted_purpose,
        authorized_invocation: true
      }.merge(context.permission_authorization.slice("system_service_identity"))
    end
  end
end
